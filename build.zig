const std = @import("std");
const llama = @import("build_llama.zig");
const server = @import("build_server.zig");
const Target = std.Build.ResolvedTarget;
const ArrayList = std.ArrayList;
const CompileStep = std.Build.Step.Compile;
const ConfigHeader = std.Build.Step.ConfigHeader;
const OptimizeMode = std.builtin.OptimizeMode;
const TranslateCStep = std.Build.TranslateCStep;
const Module = std.Build.Module;

pub const clblast = @import("clblast");

pub const llama_cpp_path_prefix = "llama.cpp/"; // point to where llama.cpp root is

pub const Options = struct {
    target: Target,
    optimize: OptimizeMode,
    clblast: bool = false,
    source_path: []const u8 = "",
    backends: llama.Backends = .{},
};

/// Build context
pub const Context = struct {
    const Self = @This();
    b: *std.Build,
    options: Options,
    /// llama.cpp build context
    llama: llama.Context,
    /// zig module
    module: *Module,
    /// llama.h translated header file module, mostly for internal use
    llama_h_module: *Module,
    /// ggml.h  translated header file module, mostly for internal use
    ggml_h_module: *Module,
    /// HuggingFace Hub integration module
    hf_hub_module: *Module,
    /// Memory-mapped file (GGUF) handling module
    zenmap_module: *Module,

    pub fn init(b: *std.Build, options: Options) Self {
        var llama_cpp = llama.Context.init(b, .{
            .target = options.target,
            .optimize = options.optimize,
            .shared = false,
            .backends = options.backends,
        });

        const llama_h_module = llama_cpp.moduleLlama();
        const ggml_h_module = llama_cpp.moduleGgml();

        // Import dependencies
        const hf_hub_dep = b.dependency("hf_hub_zig", .{
            .target = options.target,
            .optimize = options.optimize,
        });
        const hf_hub_module = hf_hub_dep.module("hf-hub");

        const zenmap_dep = b.dependency("zenmap", .{
            .target = options.target,
            .optimize = options.optimize,
        });
        const zenmap_module = zenmap_dep.module("zenmap");

        const imports: []const std.Build.Module.Import = &.{
            .{
                .name = "llama.h",
                .module = llama_h_module,
            },
            .{
                .name = "ggml.h",
                .module = ggml_h_module,
            },
            .{
                .name = "hf-hub",
                .module = hf_hub_module,
            },
            .{
                .name = "zenmap",
                .module = zenmap_module,
            },
        };
        const mod = b.createModule(.{
            .root_source_file = b.path(b.pathJoin(&.{ options.source_path, "llama.cpp.zig/llama.zig" })),
            .imports = imports,
        });

        return .{
            .b = b,
            .options = options,
            .llama = llama_cpp,
            .module = mod,
            .llama_h_module = llama_h_module,
            .ggml_h_module = ggml_h_module,
            .hf_hub_module = hf_hub_module,
            .zenmap_module = zenmap_module,
        };
    }

    pub fn link(self: *Self, comp: *CompileStep) void {
        self.llama.link(comp);
    }

    pub fn sample(self: *Self, path: []const u8, name: []const u8) void {
        const b = self.b;
        const exe_module = b.createModule(.{
            .root_source_file = b.path(b.pathJoin(&.{ path, std.mem.join(b.allocator, "", &.{ name, ".zig" }) catch @panic("OOM") })),
            .target = self.options.target,
            .optimize = self.options.optimize,
        });
        var exe = b.addExecutable(.{
            .name = name,
            .root_module = exe_module,
        });
        exe.stack_size = 32 * 1024 * 1024;
        exe.root_module.addImport("llama", self.module);
        self.link(exe);
        b.installArtifact(exe); // location when the user invokes the "install" step (the default step when running `zig build`).

        const run_exe = b.addRunArtifact(exe);
        if (b.args) |args| run_exe.addArgs(args); // passes on args like: zig build run -- my fancy args
        run_exe.step.dependOn(b.default_step); // allways copy output, to avoid confusion
        b.step(b.fmt("run-{s}", .{name}), b.fmt("Run {s} example", .{name})).dependOn(&run_exe.step);
    }
};

pub fn build(b: *std.Build) !void {
    const install_cpp_samples = b.option(bool, "cpp_samples", "Install llama.cpp samples") orelse false;

    // Custom llama.cpp version options
    const llama_ref = b.option([]const u8, "llama_ref", "llama.cpp git ref (branch/tag/commit) to fetch");
    const llama_url = b.option([]const u8, "llama_url", "llama.cpp git URL") orelse "https://github.com/ggerganov/llama.cpp";

    // If llama_ref is specified, fetch llama.cpp from git
    if (llama_ref) |ref| {
        const fetch_step = fetchLlamaCpp(b, llama_url, ref);
        b.default_step.dependOn(&fetch_step.step);
    }

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    var llama_zig = Context.init(b, .{
        .target = target,
        .optimize = optimize,
    });

    llama_zig.llama.samples(install_cpp_samples) catch |err| std.log.err("Can't build CPP samples, error: {}", .{err});

    llama_zig.sample("examples", "simple");
    // llama_zig.sample("examples", "interactive");

    // Build igllama CLI executable
    {
        const cli_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        });

        // Add imports for CLI
        cli_module.addImport("llama", llama_zig.module);
        cli_module.addImport("hf-hub", llama_zig.hf_hub_module);
        cli_module.addImport("zenmap", llama_zig.zenmap_module);

        var cli_exe = b.addExecutable(.{
            .name = "igllama",
            .root_module = cli_module,
        });
        cli_exe.stack_size = 32 * 1024 * 1024;
        llama_zig.link(cli_exe);
        b.installArtifact(cli_exe);

        const run_cli = b.addRunArtifact(cli_exe);
        if (b.args) |args| run_cli.addArgs(args);
        run_cli.step.dependOn(b.default_step);
        b.step("run", "Run igllama CLI").dependOn(&run_cli.step);
    }

    // Build llama-server (optional)
    const build_server_opt = b.option(bool, "server", "Build llama-server HTTP API server") orelse false;
    if (build_server_opt) {
        const server_exe = server.buildServer(b, &llama_zig.llama, target, optimize, .{}) catch |err| {
            std.log.err("Failed to build server: {}", .{err});
            return;
        };
        b.installArtifact(server_exe);

        const run_server = server.createRunStep(b, server_exe);
        run_server.step.dependOn(b.default_step);
        b.step("run-server", "Run llama-server").dependOn(&run_server.step);
    }

    { // tests
        const test_module = b.createModule(.{
            .root_source_file = b.path("llama.cpp.zig/llama.zig"),
            .target = target,
            .optimize = optimize,
        });
        const main_tests = b.addTest(.{
            .root_module = test_module,
        });
        llama_zig.link(main_tests);
        main_tests.root_module.addImport("llama.h", llama_zig.llama_h_module);
        const run_main_tests = b.addRunArtifact(main_tests);

        // CLI/config tests
        const cli_test_module = b.createModule(.{
            .root_source_file = b.path("src/config.zig"),
            .target = target,
            .optimize = optimize,
        });
        const cli_tests = b.addTest(.{
            .root_module = cli_test_module,
        });
        const run_cli_tests = b.addRunArtifact(cli_tests);

        const test_step = b.step("test", "Run library tests");
        test_step.dependOn(&run_main_tests.step);
        test_step.dependOn(&run_cli_tests.step);
    }
}

/// Fetch llama.cpp from git at a specific ref
fn fetchLlamaCpp(b: *std.Build, url: []const u8, ref: []const u8) *std.Build.Step.Run {
    // Remove existing llama.cpp directory if fetching custom version
    const rm_step = b.addSystemCommand(&.{
        if (@import("builtin").os.tag == .windows) "cmd" else "rm",
        if (@import("builtin").os.tag == .windows) "/c" else "-rf",
        if (@import("builtin").os.tag == .windows) "rmdir /s /q llama.cpp 2>nul || exit 0" else "llama.cpp",
    });

    // Clone the repository at the specified ref
    const clone_step = b.addSystemCommand(&.{
        "git",
        "clone",
        "--depth=1",
        "--branch",
        ref,
        url,
        "llama.cpp",
    });
    clone_step.step.dependOn(&rm_step.step);

    // Print info about the fetch
    std.log.info("Fetching llama.cpp from {s} at ref: {s}", .{ url, ref });

    return clone_step;
}
