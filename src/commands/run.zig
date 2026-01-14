const std = @import("std");
const llama = @import("llama");
const gguf = @import("../gguf.zig");
const grammar_utils = @import("../grammar.zig");

pub fn run(args: []const []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    // Parse arguments
    var model_path: ?[:0]const u8 = null;
    var prompt: ?[]const u8 = null;
    var gpu_layers: i32 = 0;
    var max_tokens: usize = 512;
    var grammar_string: ?[]const u8 = null;
    var grammar_file: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--prompt") or std.mem.eql(u8, arg, "-p")) {
            if (i + 1 < args.len) {
                prompt = args[i + 1];
                i += 1;
            } else {
                try stderr.print("Error: --prompt requires an argument\n", .{});
                return error.InvalidArguments;
            }
        } else if (std.mem.eql(u8, arg, "--gpu-layers") or std.mem.eql(u8, arg, "-ngl")) {
            if (i + 1 < args.len) {
                gpu_layers = std.fmt.parseInt(i32, args[i + 1], 10) catch {
                    try stderr.print("Error: --gpu-layers requires a number\n", .{});
                    return error.InvalidArguments;
                };
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--max-tokens") or std.mem.eql(u8, arg, "-n")) {
            if (i + 1 < args.len) {
                max_tokens = std.fmt.parseInt(usize, args[i + 1], 10) catch {
                    try stderr.print("Error: --max-tokens requires a number\n", .{});
                    return error.InvalidArguments;
                };
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--grammar") or std.mem.eql(u8, arg, "-g")) {
            if (i + 1 < args.len) {
                grammar_string = args[i + 1];
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--grammar-file") or std.mem.eql(u8, arg, "-gf")) {
            if (i + 1 < args.len) {
                grammar_file = args[i + 1];
                i += 1;
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            // This is the model path - need to convert to null-terminated
            const path_z = try allocator.allocSentinel(u8, arg.len, 0);
            @memcpy(path_z, arg);
            model_path = path_z;
        }
    }

    if (model_path == null) {
        try stderr.print("Error: Missing model path\n", .{});
        try stderr.print("Usage: igllama run <model.gguf> --prompt \"...\"\n", .{});
        try stderr.print("\nOptions:\n", .{});
        try stderr.print("  -p, --prompt <text>      Prompt text (required)\n", .{});
        try stderr.print("  -n, --max-tokens <n>     Max tokens to generate (default: 512)\n", .{});
        try stderr.print("  -ngl, --gpu-layers <n>   GPU layers to offload (default: 0)\n", .{});
        try stderr.print("  -g, --grammar <gbnf>     GBNF grammar string for constrained output\n", .{});
        try stderr.print("  -gf, --grammar-file <f>  Path to GBNF grammar file\n", .{});
        try stderr.print("                           Use 'json' or 'json-array' for built-in grammars\n", .{});
        try stderr.print("\nExample: igllama run ./model.gguf --prompt \"Hello, world!\"\n", .{});
        try stderr.print("Example: igllama run ./model.gguf --prompt \"List 3 items\" -gf json-array\n", .{});
        return error.InvalidArguments;
    }

    if (prompt == null) {
        try stderr.print("Error: Missing prompt\n", .{});
        try stderr.print("Usage: igllama run <model.gguf> --prompt \"...\"\n", .{});
        return error.InvalidArguments;
    }

    defer if (model_path) |p| allocator.free(p);

    // Validate GGUF file before loading
    const validation = gguf.validateFile(model_path.?);
    if (!validation.valid) {
        try stderr.print("Error: Invalid model file: {s}\n", .{validation.error_message orelse "Unknown error"});
        try stderr.print("\nPlease ensure you have a valid GGUF model file.\n", .{});
        return error.InvalidGgufFile;
    }

    try stdout.print("Loading model: {s}\n", .{model_path.?});
    try stdout.flush();

    // Initialize llama backend
    llama.Backend.init();
    defer llama.Backend.deinit();

    // Load model
    var mparams = llama.Model.defaultParams();
    mparams.n_gpu_layers = gpu_layers;

    const model = llama.Model.initFromFile(model_path.?.ptr, mparams) catch |err| {
        try stderr.print("Error loading model: {}\n", .{err});
        return err;
    };
    defer model.deinit();

    // Setup context
    var cparams = llama.Context.defaultParams();
    const n_ctx_train = model.nCtxTrain();
    cparams.n_ctx = @intCast(n_ctx_train);

    const cpu_threads = try std.Thread.getCpuCount();
    cparams.n_threads = @intCast(@min(cpu_threads, 4));
    cparams.n_threads_batch = @intCast(cpu_threads / 2);
    cparams.no_perf = false;

    const ctx = llama.Context.initWithModel(model, cparams) catch |err| {
        try stderr.print("Error creating context: {}\n", .{err});
        return err;
    };
    defer ctx.deinit();

    // Tokenize prompt - need vocab first
    const vocab = model.vocab() orelse {
        try stderr.print("Error: Model missing vocabulary\n", .{});
        return error.MissingVocabulary;
    };

    // Load grammar if specified
    var effective_grammar: ?[:0]const u8 = null;
    defer if (effective_grammar) |g| allocator.free(g);

    if (grammar_string) |gs| {
        // Validate grammar syntax before using
        if (grammar_utils.validateGrammar(gs)) |err_msg| {
            try stderr.print("Error: Invalid grammar: {s}\n", .{err_msg});
            return error.InvalidGrammar;
        }
        effective_grammar = try allocator.dupeZ(u8, gs);
    } else if (grammar_file) |gf| {
        const loaded = grammar_utils.loadGrammar(allocator, gf) catch |err| {
            try stderr.print("Error loading grammar file '{s}': {}\n", .{ gf, err });
            return error.InvalidGrammar;
        };
        // Validate grammar syntax before using
        if (grammar_utils.validateGrammar(loaded)) |err_msg| {
            allocator.free(loaded);
            try stderr.print("Error: Invalid grammar in '{s}': {s}\n", .{ gf, err_msg });
            return error.InvalidGrammar;
        }
        effective_grammar = loaded;
        if (std.mem.eql(u8, gf, "json") or std.mem.eql(u8, gf, "json-array")) {
            try stdout.print("Using built-in {s} grammar\n", .{gf});
        } else {
            try stdout.print("Loaded grammar from: {s}\n", .{gf});
        }
    }

    // Setup sampler
    var sampler = llama.Sampler.initChain(.{ .no_perf = false });
    defer sampler.deinit();

    // Add grammar sampler first if specified
    if (effective_grammar) |grammar| {
        sampler.add(llama.Sampler.initGrammar(vocab, grammar, "root"));
    }

    sampler.add(llama.Sampler.initGreedy());

    var tokenizer = llama.Tokenizer.init(allocator);
    defer tokenizer.deinit();
    try tokenizer.tokenize(vocab, prompt.?, false, true);

    var detokenizer = llama.Detokenizer.init(allocator);
    defer detokenizer.deinit();

    // Print prompt tokens
    for (tokenizer.getTokens()) |tok| {
        _ = try detokenizer.detokenize(vocab, tok);
    }
    try stdout.print("{s}", .{detokenizer.getText()});
    try stdout.flush();
    detokenizer.clearRetainingCapacity();

    // Generate
    var batch = llama.Batch.initOne(tokenizer.getTokens());
    var batch_token: [1]llama.Token = undefined;

    for (0..max_tokens) |_| {
        try batch.decode(ctx);
        const token = sampler.sample(ctx, -1);
        if (vocab.isEog(token)) break;

        batch_token[0] = token;
        batch = llama.Batch.initOne(batch_token[0..]);

        // Print token as it's generated
        try stdout.print("{s}", .{try detokenizer.detokenize(vocab, token)});
        try stdout.flush();
        detokenizer.clearRetainingCapacity();
    }

    try stdout.print("\n", .{});
}
