const std = @import("std");
const llama = @import("build_llama.zig");

const CompileStep = std.Build.Step.Compile;
const LazyPath = std.Build.LazyPath;
const Target = std.Build.ResolvedTarget;

pub const ServerOptions = struct {
    enable_ssl: bool = false,
};

/// Build the llama-server executable
/// This builds the C++ server from llama.cpp/tools/server
pub fn buildServer(
    b: *std.Build,
    llama_ctx: *llama.Context,
    target: Target,
    optimize: std.builtin.OptimizeMode,
    options: ServerOptions,
) !*CompileStep {
    // First, generate the asset header files
    const index_hpp = try generateAssetHeader(b, "llama.cpp/tools/server/public/index.html.gz");
    const loading_hpp = try generateAssetHeader(b, "llama.cpp/tools/server/public/loading.html");

    // Create server executable (C++ based - no Zig root source)
    const server_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });
    const server_exe = b.addExecutable(.{
        .name = "llama-server",
        .root_module = server_module,
    });

    // Include paths
    server_exe.addIncludePath(llama_ctx.path(&.{"include"}));
    server_exe.addIncludePath(llama_ctx.path(&.{"common"}));
    server_exe.addIncludePath(llama_ctx.path(&.{ "ggml", "include" }));
    server_exe.addIncludePath(llama_ctx.path(&.{ "ggml", "src" }));
    server_exe.addIncludePath(llama_ctx.path(&.{ "tools", "server" }));
    server_exe.addIncludePath(llama_ctx.path(&.{ "vendor", "nlohmann" })); // Add nlohmann json headers
    // Add llama.cpp root for includes like "common/base64.hpp"
    server_exe.addIncludePath(llama_ctx.path(&.{}));

    // Add generated headers directories (both assets are in same dir but we ensure both are generated)
    server_exe.addIncludePath(index_hpp.dirname());
    server_exe.addIncludePath(loading_hpp.dirname());

    // C++ flags for server
    const cpp_flags = &[_][]const u8{
        "-std=c++17",
        "-fexceptions",
        "-fno-sanitize=undefined",
        "-DNDEBUG",
        "-Wno-unknown-attributes", // Ignore gnu_printf attribute warnings
    };

    // Add server.cpp (common library is already linked via llama_ctx.link)
    server_exe.addCSourceFile(.{
        .file = llama_ctx.path(&.{ "tools", "server", "server.cpp" }),
        .flags = cpp_flags,
    });

    // Link llama library (includes common library)
    llama_ctx.link(server_exe);
    server_exe.linkLibCpp();

    // Platform-specific configuration
    switch (target.result.os.tag) {
        .windows => {
            server_exe.linkSystemLibrary("ws2_32");
            // Note: _WIN32_WINNT is already defined by Zig, don't redefine
            server_exe.root_module.addCMacro("NOMINMAX", "");
        },
        .linux, .freebsd, .netbsd, .openbsd => {
            // pthread is typically linked automatically with libstdc++
        },
        .macos => {
            // pthread is typically linked automatically
        },
        else => {},
    }

    // SSL support (optional)
    if (options.enable_ssl) {
        server_exe.root_module.addCMacro("CPPHTTPLIB_OPENSSL_SUPPORT", "");
        switch (target.result.os.tag) {
            .windows => {
                // Would need OpenSSL for Windows
            },
            .linux, .freebsd, .netbsd, .openbsd => {
                server_exe.linkSystemLibrary("ssl");
                server_exe.linkSystemLibrary("crypto");
            },
            .macos => {
                server_exe.linkFramework("Security");
            },
            else => {},
        }
    }

    return server_exe;
}

/// Generate a C++ header file from a binary asset using xxd-style embedding
fn generateAssetHeader(b: *std.Build, input_path: []const u8) !LazyPath {
    // Build the asset generator tool for the host
    const gen_module = b.createModule(.{
        .root_source_file = b.path("tools/generate_asset.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseFast,
    });
    const asset_gen = b.addExecutable(.{
        .name = "generate-asset",
        .root_module = gen_module,
    });

    // Get output filename (input.hpp)
    const basename = std.fs.path.basename(input_path);
    const output_name = b.fmt("{s}.hpp", .{basename});

    // Run the generator
    const run_gen = b.addRunArtifact(asset_gen);
    run_gen.addArg("--input");
    run_gen.addFileArg(b.path(input_path));
    run_gen.addArg("--output");
    const output = run_gen.addOutputFileArg(output_name);

    return output;
}

/// Create a run step for the server
pub fn createRunStep(b: *std.Build, server_exe: *CompileStep) *std.Build.Step.Run {
    const run_cmd = b.addRunArtifact(server_exe);

    // Pass through user arguments
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    return run_cmd;
}
