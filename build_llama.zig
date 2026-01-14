const std = @import("std");
const Builder = std.Build;
const Target = std.Build.ResolvedTarget;
const OptimizeMode = std.builtin.OptimizeMode;
const CompileStep = std.Build.Step.Compile;
const LazyPath = std.Build.LazyPath;
const Module = std.Build.Module;

pub const Backends = struct {
    cpu: bool = true,
    metal: bool = false,
    // untested possibly unsupported at the moment:
    cuda: bool = false,
    sycl: bool = false,
    vulkan: bool = false,
    opencl: bool = false,
    cann: bool = false,
    blas: bool = false,
    rpc: bool = false,
    kompute: bool = false,

    pub fn addDefines(self: @This(), comp: *CompileStep) void {
        if (self.cuda) comp.root_module.addCMacro("GGML_USE_CUDA", "");
        if (self.metal) comp.root_module.addCMacro("GGML_USE_METAL", "");
        if (self.sycl) comp.root_module.addCMacro("GGML_USE_SYCL", "");
        if (self.vulkan) comp.root_module.addCMacro("GGML_USE_VULKAN", "");
        if (self.opencl) comp.root_module.addCMacro("GGML_USE_OPENCL", "");
        if (self.cann) comp.root_module.addCMacro("GGML_USE_CANN", "");
        if (self.blas) comp.root_module.addCMacro("GGML_USE_BLAS", "");
        if (self.rpc) comp.root_module.addCMacro("GGML_USE_RPC", "");
        if (self.kompute) comp.root_module.addCMacro("GGML_USE_KOMPUTE", "");
        if (self.cpu) comp.root_module.addCMacro("GGML_USE_CPU", "");
    }
};

pub const Options = struct {
    target: Target,
    optimize: OptimizeMode,
    backends: Backends = .{},
    shared: bool, // static or shared lib
    build_number: usize = 0, // number that will be writen in build info
    metal_ndebug: bool = false,
    metal_use_bf16: bool = false,
    httplib: bool = false, // Enable cpp-httplib for remote content fetching
};

// Build context
pub const Context = struct {
    b: *Builder,
    options: Options,
    build_info: *CompileStep,
    path_prefix: []const u8 = "",
    lib: ?*CompileStep = null,

    pub fn init(b: *Builder, op: Options) Context {
        const path_prefix = b.pathJoin(&.{ thisPath(), "/llama.cpp" });
        const zig_version = @import("builtin").zig_version_string;
        const commit_hash = std.process.Child.run(
            .{ .allocator = b.allocator, .argv = &.{ "git", "rev-parse", "HEAD" } },
        ) catch |err| {
            std.log.err("Cant get git comiit hash! err: {}", .{err});
            unreachable;
        };

        const build_info_zig = true; // use cpp or zig file for build-info
        const build_info_path = b.pathJoin(&.{ "common", "build-info." ++ if (build_info_zig) "zig" else "cpp" });
        const build_info = b.fmt(if (build_info_zig)
            \\pub export var LLAMA_BUILD_NUMBER : c_int = {};
            \\pub export var LLAMA_COMMIT = "{s}";
            \\pub export var LLAMA_COMPILER = "Zig {s}";
            \\pub export var LLAMA_BUILD_TARGET = "{s}_{s}";
            \\
        else
            \\int LLAMA_BUILD_NUMBER = {};
            \\char const *LLAMA_COMMIT = "{s}";
            \\char const *LLAMA_COMPILER = "Zig {s}";
            \\char const *LLAMA_BUILD_TARGET = "{s}_{s}";
            \\
        , .{ op.build_number, commit_hash.stdout[0 .. commit_hash.stdout.len - 1], zig_version, op.target.result.zigTriple(b.allocator) catch unreachable, @tagName(op.optimize) });

        const build_info_module = b.createModule(.{
            .root_source_file = b.addWriteFiles().add(build_info_path, build_info),
            .target = op.target,
            .optimize = op.optimize,
        });

        return .{
            .b = b,
            .options = op,
            .path_prefix = path_prefix,
            .build_info = b.addObject(.{ .name = "llama-build-info", .root_module = build_info_module }),
        };
    }

    /// just builds everything needed and links it to your target
    pub fn link(ctx: *Context, comp: *CompileStep) void {
        const lib = ctx.library();
        comp.linkLibrary(lib);
        if (ctx.options.shared) ctx.b.installArtifact(lib);
    }

    /// build single library containing everything
    pub fn library(ctx: *Context) *CompileStep {
        if (ctx.lib) |l| return l;
        const lib_module = ctx.b.createModule(.{
            .target = ctx.options.target,
            .optimize = ctx.options.optimize,
        });
        const linkage: std.builtin.LinkMode = if (ctx.options.shared) .dynamic else .static;
        const lib = ctx.b.addLibrary(.{ .name = "llama.cpp", .root_module = lib_module, .linkage = linkage });
        if (ctx.options.shared) {
            lib.root_module.addCMacro("LLAMA_SHARED", "");
            lib.root_module.addCMacro("LLAMA_BUILD", "");
            if (ctx.options.target.result.os.tag == .windows) {
                std.log.warn("For shared linking to work, requires header llama.h modification:\n\'#    if defined(_WIN32) && (!defined(__MINGW32__) || defined(ZIG))'", .{});
                lib.root_module.addCMacro("ZIG", "");
            }
        }
        ctx.options.backends.addDefines(lib);
        if (ctx.options.httplib) {
            lib.root_module.addCMacro("LLAMA_USE_HTTPLIB", "");
        }
        ctx.addAll(lib);
        if (ctx.options.target.result.abi != .msvc)
            lib.root_module.addCMacro("_GNU_SOURCE", "");
        ctx.lib = lib;
        return lib;
    }

    /// link everything directly to target
    pub fn addAll(ctx: *Context, compile: *CompileStep) void {
        ctx.addBuildInfo(compile);
        ctx.addGgml(compile);
        ctx.addLLama(compile);
    }

    /// zig module with translated headers
    pub fn moduleLlama(ctx: *Context) *Module {
        const tc = ctx.b.addTranslateC(.{
            .root_source_file = ctx.includePath("llama.h"),
            .target = ctx.options.target,
            .optimize = ctx.options.optimize,
        });
        if (ctx.options.shared) tcDefineCMacro(tc, "LLAMA_SHARED", null);
        tc.addSystemIncludePath(ctx.path(&.{ "ggml", "include" }));
        tcDefineCMacro(tc, "NDEBUG", null); // otherwise zig is unhappy about c ASSERT macro
        return tc.addModule("llama.h");
    }

    /// zig module with translated headers
    pub fn moduleGgml(ctx: *Context) *Module {
        const tc = ctx.b.addTranslateC(.{
            .root_source_file = ctx.path(&.{ "ggml", "include", "ggml.h" }),
            .target = ctx.options.target,
            .optimize = ctx.options.optimize,
        });

        tcDefineCMacro(tc, "LLAMA_SHARED", null);
        tcDefineCMacro(tc, "NDEBUG", null);

        return tc.addModule("ggml.h");
    }

    pub fn addBuildInfo(ctx: *Context, compile: *CompileStep) void {
        compile.addObject(ctx.build_info);
    }

    pub fn addGgml(ctx: *Context, compile: *CompileStep) void {
        ctx.common(compile);
        compile.addIncludePath(ctx.path(&.{ "ggml", "include" }));
        compile.addIncludePath(ctx.path(&.{ "ggml", "src" }));

        if (ctx.options.target.result.os.tag == .windows) {
            compile.root_module.addCMacro("GGML_ATTRIBUTE_FORMAT(...)", "");
        }

        // GGML version defines (from ggml/CMakeLists.txt)
        compile.root_module.addCMacro("GGML_VERSION", "\"0.9.5\"");
        compile.root_module.addCMacro("GGML_COMMIT", "\"unknown\"");

        var sources: std.ArrayList(LazyPath) = .empty;
        sources.appendSlice(ctx.b.allocator, &.{
            ctx.path(&.{ "ggml", "src", "ggml-alloc.c" }),
            ctx.path(&.{ "ggml", "src", "ggml-backend-reg.cpp" }),
            ctx.path(&.{ "ggml", "src", "ggml-backend.cpp" }),
            ctx.path(&.{ "ggml", "src", "ggml-opt.cpp" }),
            ctx.path(&.{ "ggml", "src", "ggml-quants.c" }),
            ctx.path(&.{ "ggml", "src", "ggml-threading.cpp" }),
            ctx.path(&.{ "ggml", "src", "ggml.c" }),
            ctx.path(&.{ "ggml", "src", "ggml.cpp" }),
            ctx.path(&.{ "ggml", "src", "gguf.cpp" }),
        }) catch unreachable;

        if (ctx.options.backends.cpu) {
            compile.addIncludePath(ctx.path(&.{ "ggml", "src", "ggml-cpu" }));
            compile.linkLibCpp();
            sources.appendSlice(ctx.b.allocator, &.{
                // Core CPU files
                ctx.path(&.{ "ggml", "src", "ggml-cpu", "ggml-cpu.c" }),
                ctx.path(&.{ "ggml", "src", "ggml-cpu", "ggml-cpu.cpp" }),
                ctx.path(&.{ "ggml", "src", "ggml-cpu", "binary-ops.cpp" }),
                ctx.path(&.{ "ggml", "src", "ggml-cpu", "unary-ops.cpp" }),
                ctx.path(&.{ "ggml", "src", "ggml-cpu", "hbm.cpp" }),
                ctx.path(&.{ "ggml", "src", "ggml-cpu", "quants.c" }),
                ctx.path(&.{ "ggml", "src", "ggml-cpu", "traits.cpp" }),
                ctx.path(&.{ "ggml", "src", "ggml-cpu", "ops.cpp" }),
                ctx.path(&.{ "ggml", "src", "ggml-cpu", "repack.cpp" }),
                ctx.path(&.{ "ggml", "src", "ggml-cpu", "vec.cpp" }),
                // AMX (Intel Advanced Matrix Extensions)
                ctx.path(&.{ "ggml", "src", "ggml-cpu", "amx", "amx.cpp" }),
                ctx.path(&.{ "ggml", "src", "ggml-cpu", "amx", "mmq.cpp" }),
            }) catch unreachable;

            // Architecture-specific optimized quantization and repacking
            const arch = ctx.options.target.result.cpu.arch;
            if (arch == .x86_64 or arch == .x86) {
                sources.appendSlice(ctx.b.allocator, &.{
                    ctx.path(&.{ "ggml", "src", "ggml-cpu", "arch", "x86", "quants.c" }),
                    ctx.path(&.{ "ggml", "src", "ggml-cpu", "arch", "x86", "repack.cpp" }),
                    ctx.path(&.{ "ggml", "src", "ggml-cpu", "arch", "x86", "cpu-feats.cpp" }),
                }) catch unreachable;
            } else if (arch == .aarch64 or arch == .arm) {
                sources.appendSlice(ctx.b.allocator, &.{
                    ctx.path(&.{ "ggml", "src", "ggml-cpu", "arch", "arm", "quants.c" }),
                    ctx.path(&.{ "ggml", "src", "ggml-cpu", "arch", "arm", "repack.cpp" }),
                    ctx.path(&.{ "ggml", "src", "ggml-cpu", "arch", "arm", "cpu-feats.cpp" }),
                }) catch unreachable;
            } else if (arch == .powerpc64 or arch == .powerpc64le or arch == .powerpc) {
                sources.appendSlice(ctx.b.allocator, &.{
                    ctx.path(&.{ "ggml", "src", "ggml-cpu", "arch", "powerpc", "quants.c" }),
                }) catch unreachable;
            } else if (arch == .riscv64) {
                sources.appendSlice(ctx.b.allocator, &.{
                    ctx.path(&.{ "ggml", "src", "ggml-cpu", "arch", "riscv", "quants.c" }),
                    ctx.path(&.{ "ggml", "src", "ggml-cpu", "arch", "riscv", "repack.cpp" }),
                }) catch unreachable;
            } else if (arch == .wasm32 or arch == .wasm64) {
                sources.appendSlice(ctx.b.allocator, &.{
                    ctx.path(&.{ "ggml", "src", "ggml-cpu", "arch", "wasm", "quants.c" }),
                }) catch unreachable;
            } else if (arch == .s390x) {
                sources.appendSlice(ctx.b.allocator, &.{
                    ctx.path(&.{ "ggml", "src", "ggml-cpu", "arch", "s390", "quants.c" }),
                }) catch unreachable;
            }
            // Note: loongarch64 would need similar handling if supported by Zig
        }

        if (ctx.options.backends.metal) {
            compile.addIncludePath(ctx.path(&.{ "ggml", "src", "ggml-metal" }));
            compile.linkLibCpp();
            compile.root_module.addCMacro("GGML_METAL", "");
            if (ctx.options.metal_ndebug) {
                compile.root_module.addCMacro("GGML_METAL_NDEBUG", "");
            }
            if (ctx.options.metal_use_bf16) {
                compile.root_module.addCMacro("GGML_METAL_USE_BF16", "");
            }
            // Create a separate Metal library
            const metal_module = ctx.b.createModule(.{
                .target = ctx.options.target,
                .optimize = ctx.options.optimize,
            });
            const metal_lib = ctx.b.addLibrary(.{
                .name = "ggml-metal",
                .root_module = metal_module,
                .linkage = .static,
            });
            metal_lib.addIncludePath(ctx.path(&.{ "ggml", "include" }));
            metal_lib.addIncludePath(ctx.path(&.{ "ggml", "src" }));
            metal_lib.addIncludePath(ctx.path(&.{ "ggml", "src", "ggml-metal" }));
            metal_lib.linkFramework("Foundation");
            metal_lib.linkFramework("AppKit");
            metal_lib.linkFramework("Metal");
            metal_lib.linkFramework("MetalKit");
            // New llama.cpp metal file structure (multiple .cpp and .m files)
            metal_lib.addCSourceFile(.{ .file = ctx.path(&.{ "ggml", "src", "ggml-metal", "ggml-metal.cpp" }), .flags = ctx.flags() });
            metal_lib.addCSourceFile(.{ .file = ctx.path(&.{ "ggml", "src", "ggml-metal", "ggml-metal-common.cpp" }), .flags = ctx.flags() });
            metal_lib.addCSourceFile(.{ .file = ctx.path(&.{ "ggml", "src", "ggml-metal", "ggml-metal-device.cpp" }), .flags = ctx.flags() });
            metal_lib.addCSourceFile(.{ .file = ctx.path(&.{ "ggml", "src", "ggml-metal", "ggml-metal-ops.cpp" }), .flags = ctx.flags() });
            metal_lib.addCSourceFile(.{ .file = ctx.path(&.{ "ggml", "src", "ggml-metal", "ggml-metal-context.m" }), .flags = ctx.flags() });
            metal_lib.addCSourceFile(.{ .file = ctx.path(&.{ "ggml", "src", "ggml-metal", "ggml-metal-device.m" }), .flags = ctx.flags() });
            const metal_files = [_][]const u8{
                "ggml-metal.metal",
                "ggml-metal-impl.h",
            };
            // Compile the metal shader [requires xcode installed]
            const metal_compile = ctx.b.addSystemCommand(&.{
                "xcrun", "-sdk", "macosx", "metal", "-fno-fast-math", "-g",
                "-I", ctx.b.pathJoin(&.{ ctx.b.install_path, "metal" }), // Include path for ggml-common.h
                "-c", ctx.b.pathJoin(&.{ ctx.b.install_path, "metal", "ggml-metal.metal" }),
                "-o", ctx.b.pathJoin(&.{ ctx.b.install_path, "metal", "ggml-metal.air" }),
            });
            const common_src = ctx.path(&.{ "ggml", "src", "ggml-common.h" });
            const common_dst = ctx.b.pathJoin(&.{ "metal", "ggml-common.h" }); // Install to metal directory
            const common_install_step = ctx.b.addInstallFile(common_src, common_dst);
            metal_compile.step.dependOn(&common_install_step.step);
            for (metal_files) |file| {
                const src = ctx.path(&.{ "ggml", "src", "ggml-metal", file });
                const dst = ctx.b.pathJoin(&.{ "metal", file });
                const install_step = ctx.b.addInstallFile(src, dst);
                metal_compile.step.dependOn(&install_step.step);
            }
            const metallib_compile = ctx.b.addSystemCommand(&.{
                "xcrun", "-sdk", "macosx", "metallib", ctx.b.pathJoin(&.{ ctx.b.install_path, "metal", "ggml-metal.air" }), "-o", ctx.b.pathJoin(&.{ ctx.b.install_path, "metal", "default.metallib" }),
            });
            metallib_compile.step.dependOn(&metal_compile.step);
            // Install the metal shader source file to bin directory
            const metal_shader_install = ctx.b.addInstallBinFile(ctx.path(&.{ "ggml", "src", "ggml-metal", "ggml-metal.metal" }), "ggml-metal.metal");
            const default_lib_install = ctx.b.addInstallBinFile(.{ .cwd_relative = ctx.b.pathJoin(&.{ ctx.b.install_path, "metal", "default.metallib" }) }, "default.metallib");
            metal_shader_install.step.dependOn(&metallib_compile.step);
            default_lib_install.step.dependOn(&metal_shader_install.step);
            // Link the metal library with the main compilation
            compile.linkLibrary(metal_lib);
            compile.step.dependOn(&metal_lib.step);
            compile.step.dependOn(&default_lib_install.step);
        }

        if (ctx.options.backends.vulkan) {
            compile.addIncludePath(ctx.path(&.{ "ggml", "src", "ggml-vulkan" }));
            compile.linkLibCpp();
            compile.root_module.addCMacro("GGML_VULKAN", "");

            // Build vulkan-shaders-gen tool (runs on host)
            const shaders_gen_module = ctx.b.createModule(.{
                .target = ctx.b.graph.host,
                .optimize = .ReleaseFast,
            });
            const shaders_gen = ctx.b.addExecutable(.{
                .name = "vulkan-shaders-gen",
                .root_module = shaders_gen_module,
            });
            shaders_gen.addCSourceFile(.{
                .file = ctx.path(&.{ "ggml", "src", "ggml-vulkan", "vulkan-shaders", "vulkan-shaders-gen.cpp" }),
                .flags = &.{ "-std=c++17", "-fexceptions" },
            });
            shaders_gen.linkLibCpp();
            if (ctx.options.target.result.os.tag == .windows) {
                // Windows-specific for shader gen
            }

            // Run shader generator to produce ggml-vulkan-shaders.hpp and .cpp
            const input_dir = ctx.b.pathJoin(&.{ ctx.path_prefix, "ggml", "src", "ggml-vulkan", "vulkan-shaders" });
            const output_dir = ctx.b.pathJoin(&.{ ctx.b.install_path, "vulkan-shaders-spv" });
            const target_hpp = ctx.b.pathJoin(&.{ ctx.b.install_path, "vulkan-shaders", "ggml-vulkan-shaders.hpp" });
            const target_cpp = ctx.b.pathJoin(&.{ ctx.b.install_path, "vulkan-shaders", "ggml-vulkan-shaders.cpp" });

            const run_shaders_gen = ctx.b.addRunArtifact(shaders_gen);
            run_shaders_gen.addArgs(&.{
                "--glslc",      "glslc", // Requires Vulkan SDK in PATH
                "--input-dir",  input_dir,
                "--output-dir", output_dir,
                "--target-hpp", target_hpp,
                "--target-cpp", target_cpp,
                "--no-clean",
            });

            // Add generated source files
            compile.addIncludePath(.{ .cwd_relative = ctx.b.pathJoin(&.{ ctx.b.install_path, "vulkan-shaders" }) });
            compile.addCSourceFile(.{
                .file = .{ .cwd_relative = target_cpp },
                .flags = ctx.flags(),
            });
            compile.step.dependOn(&run_shaders_gen.step);

            // Compile ggml-vulkan.cpp
            sources.append(ctx.b.allocator, ctx.path(&.{ "ggml", "src", "ggml-vulkan", "ggml-vulkan.cpp" })) catch unreachable;

            // Link Vulkan library
            if (ctx.options.target.result.os.tag == .windows) {
                compile.linkSystemLibrary("vulkan-1");
            } else {
                compile.linkSystemLibrary("vulkan");
            }
        }

        for (sources.items) |src| compile.addCSourceFile(.{ .file = src, .flags = ctx.flags() });
    }

    pub fn addLLama(ctx: *Context, compile: *CompileStep) void {
        ctx.common(compile);
        compile.addIncludePath(ctx.path(&.{"include"}));
        // Vendor directory for external dependencies (nlohmann/json, etc.)
        compile.addIncludePath(ctx.path(&.{"vendor"}));
        // Core llama source files
        compile.addCSourceFile(.{ .file = ctx.srcPath("llama-adapter.cpp"), .flags = ctx.flags() });
        compile.addCSourceFile(.{ .file = ctx.srcPath("llama-arch.cpp"), .flags = ctx.flags() });
        compile.addCSourceFile(.{ .file = ctx.srcPath("llama-batch.cpp"), .flags = ctx.flags() });
        compile.addCSourceFile(.{ .file = ctx.srcPath("llama-chat.cpp"), .flags = ctx.flags() });
        compile.addCSourceFile(.{ .file = ctx.srcPath("llama-context.cpp"), .flags = ctx.flags() });
        compile.addCSourceFile(.{ .file = ctx.srcPath("llama-cparams.cpp"), .flags = ctx.flags() });
        compile.addCSourceFile(.{ .file = ctx.srcPath("llama-grammar.cpp"), .flags = ctx.flags() });
        compile.addCSourceFile(.{ .file = ctx.srcPath("llama-graph.cpp"), .flags = ctx.flags() });
        compile.addCSourceFile(.{ .file = ctx.srcPath("llama-hparams.cpp"), .flags = ctx.flags() });
        compile.addCSourceFile(.{ .file = ctx.srcPath("llama-impl.cpp"), .flags = ctx.flags() });
        compile.addCSourceFile(.{ .file = ctx.srcPath("llama-io.cpp"), .flags = ctx.flags() });
        compile.addCSourceFile(.{ .file = ctx.srcPath("llama-kv-cache.cpp"), .flags = ctx.flags() });
        compile.addCSourceFile(.{ .file = ctx.srcPath("llama-kv-cache-iswa.cpp"), .flags = ctx.flags() });
        compile.addCSourceFile(.{ .file = ctx.srcPath("llama-memory.cpp"), .flags = ctx.flags() });
        compile.addCSourceFile(.{ .file = ctx.srcPath("llama-memory-hybrid.cpp"), .flags = ctx.flags() });
        compile.addCSourceFile(.{ .file = ctx.srcPath("llama-memory-recurrent.cpp"), .flags = ctx.flags() });
        compile.addCSourceFile(.{ .file = ctx.srcPath("llama-mmap.cpp"), .flags = ctx.flags() });
        compile.addCSourceFile(.{ .file = ctx.srcPath("llama-model-loader.cpp"), .flags = ctx.flags() });
        compile.addCSourceFile(.{ .file = ctx.srcPath("llama-model-saver.cpp"), .flags = ctx.flags() });
        compile.addCSourceFile(.{ .file = ctx.srcPath("llama-model.cpp"), .flags = ctx.flags() });
        compile.addCSourceFile(.{ .file = ctx.srcPath("llama-quant.cpp"), .flags = ctx.flags() });
        compile.addCSourceFile(.{ .file = ctx.srcPath("llama-sampling.cpp"), .flags = ctx.flags() });
        compile.addCSourceFile(.{ .file = ctx.srcPath("llama-vocab.cpp"), .flags = ctx.flags() });
        compile.addCSourceFile(.{ .file = ctx.srcPath("llama.cpp"), .flags = ctx.flags() });
        compile.addCSourceFile(.{ .file = ctx.srcPath("unicode-data.cpp"), .flags = ctx.flags() });
        compile.addCSourceFile(.{ .file = ctx.srcPath("unicode.cpp"), .flags = ctx.flags() });

        // Model-specific graph builders (src/models/*.cpp)
        ctx.addModelFiles(compile);

        // Common library files
        compile.addCSourceFile(.{ .file = ctx.path(&.{ "common", "common.cpp" }), .flags = ctx.flags() });
        compile.addCSourceFile(.{ .file = ctx.path(&.{ "common", "sampling.cpp" }), .flags = ctx.flags() });
        compile.addCSourceFile(.{ .file = ctx.path(&.{ "common", "console.cpp" }), .flags = ctx.flags() });
        compile.addCSourceFile(.{ .file = ctx.path(&.{ "common", "json-schema-to-grammar.cpp" }), .flags = ctx.flags() });
        compile.addCSourceFile(.{ .file = ctx.path(&.{ "common", "speculative.cpp" }), .flags = ctx.flags() });
        compile.addCSourceFile(.{ .file = ctx.path(&.{ "common", "ngram-cache.cpp" }), .flags = ctx.flags() });
        compile.addCSourceFile(.{ .file = ctx.path(&.{ "common", "log.cpp" }), .flags = ctx.flags() });
        compile.addCSourceFile(.{ .file = ctx.path(&.{ "common", "arg.cpp" }), .flags = ctx.flags() });
        compile.addCSourceFile(.{ .file = ctx.path(&.{ "common", "chat.cpp" }), .flags = ctx.flags() });
        compile.addCSourceFile(.{ .file = ctx.path(&.{ "common", "chat-parser.cpp" }), .flags = ctx.flags() });
        compile.addCSourceFile(.{ .file = ctx.path(&.{ "common", "chat-parser-xml-toolcall.cpp" }), .flags = ctx.flags() });
        compile.addCSourceFile(.{ .file = ctx.path(&.{ "common", "chat-peg-parser.cpp" }), .flags = ctx.flags() });
        compile.addCSourceFile(.{ .file = ctx.path(&.{ "common", "peg-parser.cpp" }), .flags = ctx.flags() });
        compile.addCSourceFile(.{ .file = ctx.path(&.{ "common", "json-partial.cpp" }), .flags = ctx.flags() });
        compile.addCSourceFile(.{ .file = ctx.path(&.{ "common", "regex-partial.cpp" }), .flags = ctx.flags() });
        compile.addCSourceFile(.{ .file = ctx.path(&.{ "common", "preset.cpp" }), .flags = ctx.flags() });
        compile.addCSourceFile(.{ .file = ctx.path(&.{ "common", "download.cpp" }), .flags = ctx.flags() });
        compile.addCSourceFile(.{ .file = ctx.path(&.{ "common", "llguidance.cpp" }), .flags = ctx.flags() });
        compile.addCSourceFile(.{ .file = ctx.path(&.{ "common", "unicode.cpp" }), .flags = ctx.flags() });
        // Generated license file (equivalent to CMake's license_generate)
        const license_file = generateLicenseFile(ctx.b, ctx.path_prefix);
        compile.addCSourceFile(.{ .file = license_file, .flags = ctx.flags() });
    }

    pub fn samples(ctx: *Context, install: bool) !void {
        const b = ctx.b;
        // Note: "main" was renamed to llama-cli and moved to tools/ in newer llama.cpp versions
        // Only include examples that exist in the current llama.cpp version
        const examples = [_][]const u8{
            "simple",
            // "simple-chat", // requires additional setup
            // "batched",
            // "embedding",
            // "lookahead",
            // "speculative",
            // "parallel",
        };

        for (examples) |ex| {
            // Check if example directory exists before trying to build
            const rpath = b.pathJoin(&.{ ctx.path_prefix, "examples", ex });
            var dir = std.fs.openDirAbsolute(b.pathFromRoot(rpath), .{ .iterate = true }) catch {
                std.log.warn("Skipping example '{s}': directory not found", .{ex});
                continue;
            };
            dir.close();

            const exe_module = b.createModule(.{
                .target = ctx.options.target,
                .optimize = ctx.options.optimize,
            });
            const exe = b.addExecutable(.{ .name = ex, .root_module = exe_module });
            exe.addIncludePath(ctx.path(&.{"include"}));
            exe.addIncludePath(ctx.path(&.{"common"}));
            exe.addIncludePath(ctx.path(&.{ "ggml", "include" }));
            exe.addIncludePath(ctx.path(&.{ "ggml", "src" }));

            exe.want_lto = false; // TODO: review, causes: error: lld-link: undefined symbol: __declspec(dllimport) _create_locale
            if (install) b.installArtifact(exe);
            { // add all c/cpp files from example dir
                exe.addIncludePath(.{ .cwd_relative = rpath });
                var dir2 = if (@hasDecl(std.fs, "openIterableDirAbsolute")) try std.fs.openIterableDirAbsolute(b.pathFromRoot(rpath), .{}) else try std.fs.openDirAbsolute(b.pathFromRoot(rpath), .{ .iterate = true }); // zig 11 vs nightly compatibility
                defer dir2.close();
                var dir_it = dir2.iterate();
                while (try dir_it.next()) |f| switch (f.kind) {
                    .file => if (std.ascii.endsWithIgnoreCase(f.name, ".c") or std.ascii.endsWithIgnoreCase(f.name, ".cpp")) {
                        const src = b.pathJoin(&.{ ctx.path_prefix, "examples", ex, f.name });
                        exe.addCSourceFile(.{ .file = .{ .cwd_relative = src }, .flags = ctx.flags() });
                    },
                    else => {},
                };
            }
            ctx.common(exe);
            ctx.link(exe);

            const run_exe = b.addRunArtifact(exe);
            if (b.args) |args| run_exe.addArgs(args); // passes on args like: zig build run -- my fancy args
            run_exe.step.dependOn(b.default_step); // allways copy output, to avoid confusion
            b.step(b.fmt("run-cpp-{s}", .{ex}), b.fmt("Run llama.cpp example: {s}", .{ex})).dependOn(&run_exe.step);
        }
    }

    fn flags(ctx: Context) []const []const u8 {
        _ = ctx;
        return &.{"-fno-sanitize=undefined"};
    }

    /// Generate license.cpp file equivalent to CMake's license_generate function
    fn generateLicenseFile(b: *Builder, path_prefix: []const u8) LazyPath {
        _ = path_prefix; // Not used in current implementation

        // Create the content for license.cpp
        const license_content =
            \\// Generated by Zig build system
            \\
            \\extern "C" const char *LICENSES[] = {
            \\    "ggml-cpu: MIT",
            \\    "llama.cpp: MIT",
            \\    nullptr
            \\};
            \\
        ;

        // Create a temporary file with the license content
        const license_file = b.cache_root.join(b.allocator, &.{"license.cpp"}) catch @panic("OOM");
        std.fs.cwd().writeFile(.{ .sub_path = license_file, .data = license_content }) catch @panic("Failed to write license file");

        return .{ .cwd_relative = license_file };
    }

    fn common(ctx: Context, lib: *CompileStep) void {
        lib.linkLibCpp();
        lib.addIncludePath(ctx.path(&.{"common"}));
        if (ctx.options.optimize != .Debug) lib.root_module.addCMacro("NDEBUG", "");
    }

    pub fn path(self: Context, subpath: []const []const u8) LazyPath {
        const sp = self.b.pathJoin(subpath);
        return .{ .cwd_relative = self.b.pathJoin(&.{ self.path_prefix, sp }) };
    }

    pub fn srcPath(self: Context, p: []const u8) LazyPath {
        return .{ .cwd_relative = self.b.pathJoin(&.{ self.path_prefix, "src", p }) };
    }

    pub fn includePath(self: Context, p: []const u8) LazyPath {
        return .{ .cwd_relative = self.b.pathJoin(&.{ self.path_prefix, "include", p }) };
    }

    /// Add all model-specific graph builders from src/models/*.cpp
    pub fn addModelFiles(ctx: Context, compile: *CompileStep) void {
        const models_path = ctx.b.pathJoin(&.{ ctx.path_prefix, "src", "models" });
        var dir = std.fs.openDirAbsolute(ctx.b.pathFromRoot(models_path), .{ .iterate = true }) catch |err| {
            std.log.err("Can't open models directory: {s}, error: {}", .{ models_path, err });
            return;
        };
        defer dir.close();

        var dir_it = dir.iterate();
        while (dir_it.next() catch null) |entry| {
            if (entry.kind == .file and std.ascii.endsWithIgnoreCase(entry.name, ".cpp")) {
                const file_path = ctx.b.pathJoin(&.{ ctx.path_prefix, "src", "models", entry.name });
                compile.addCSourceFile(.{
                    .file = .{ .cwd_relative = file_path },
                    .flags = ctx.flags(),
                });
            }
        }
    }
};

fn thisPath() []const u8 {
    return std.fs.path.dirname(@src().file) orelse ".";
}

// TODO: idk, root_module.addCMacro returns: TranslateC.zig:110:28: error: root struct of file 'Build' has no member named 'constructranslate_cMacro'
// use raw macro for now
fn tcDefineCMacro(tc: *std.Build.Step.TranslateC, comptime name: []const u8, comptime value: ?[]const u8) void {
    tc.defineCMacroRaw(name ++ "=" ++ (value orelse "1"));
}
