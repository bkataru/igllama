const std = @import("std");
const llama = @import("llama");

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
        try stderr.print("Example: igllama run ./model.gguf --prompt \"Hello, world!\"\n", .{});
        return error.InvalidArguments;
    }

    if (prompt == null) {
        try stderr.print("Error: Missing prompt\n", .{});
        try stderr.print("Usage: igllama run <model.gguf> --prompt \"...\"\n", .{});
        return error.InvalidArguments;
    }

    defer if (model_path) |p| allocator.free(p);

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

    // Setup sampler
    var sampler = llama.Sampler.initChain(.{ .no_perf = false });
    defer sampler.deinit();
    sampler.add(llama.Sampler.initGreedy());

    // Tokenize prompt
    const vocab = model.vocab() orelse {
        try stderr.print("Error: Model missing vocabulary\n", .{});
        return error.MissingVocabulary;
    };

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
