const std = @import("std");
const llama = @import("llama");
const slog = std.log.scoped(.streaming);
const arg_utils = @import("utils/args.zig");

const Model = llama.Model;
const Context = llama.Context;
const Token = llama.Token;

/// Streaming generation example demonstrating real-time token output.
/// This example shows how to:
/// - Stream tokens as they are generated
/// - Measure generation performance (tokens/sec)
/// - Handle generation with callbacks
pub const Args = struct {
    model_path: [:0]const u8 = "models/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf",
    prompt: []const u8 = "Write a short poem about programming:",
    max_tokens: usize = 256,
    seed: ?u32 = null,
    threads: ?usize = null,
    gpu_layers: i32 = 0,
    temperature: f32 = 0.8,
    show_stats: bool = true,
};

pub fn run(alloc: std.mem.Allocator, args: Args) !void {
    llama.Backend.init();
    defer llama.Backend.deinit();

    // Suppress verbose logging
    llama.logSet(null, null);

    std.debug.print("Loading model...\n", .{});
    const load_start = std.time.milliTimestamp();

    var mparams = Model.defaultParams();
    mparams.n_gpu_layers = args.gpu_layers;
    const model = try Model.initFromFile(args.model_path.ptr, mparams);
    defer model.deinit();

    var cparams = Context.defaultParams();
    cparams.n_ctx = @intCast(model.nCtxTrain());

    const cpu_threads = try std.Thread.getCpuCount();
    cparams.n_threads = @intCast(args.threads orelse @min(cpu_threads, 4));
    cparams.n_threads_batch = @intCast(cpu_threads / 2);
    cparams.no_perf = false;

    const ctx = try Context.initWithModel(model, cparams);
    defer ctx.deinit();

    const load_time = std.time.milliTimestamp() - load_start;
    std.debug.print("Model loaded in {d:.2}s\n\n", .{@as(f64, @floatFromInt(load_time)) / 1000.0});

    // Setup sampler
    var sampler = llama.Sampler.initChain(.{ .no_perf = false });
    defer sampler.deinit();
    sampler.add(llama.Sampler.initTemp(args.temperature));
    sampler.add(llama.Sampler.initDist(args.seed orelse @truncate(@as(u64, @bitCast(std.time.milliTimestamp())))));

    const vocab = model.vocab() orelse @panic("model missing vocab!");

    // Tokenize prompt
    var tokenizer = llama.Tokenizer.init(alloc);
    defer tokenizer.deinit();
    try tokenizer.tokenize(vocab, args.prompt, false, true);

    const prompt_tokens = tokenizer.getTokens().len;
    std.debug.print("Prompt: {s}\n", .{args.prompt});
    std.debug.print("Prompt tokens: {d}\n", .{prompt_tokens});
    std.debug.print("---\n", .{});

    // Generate with streaming
    var detokenizer = llama.Detokenizer.init(alloc);
    defer detokenizer.deinit();

    var batch = llama.Batch.initOne(tokenizer.getTokens());
    var batch_token: [1]Token = undefined;

    var generated_tokens: usize = 0;
    const gen_start = std.time.milliTimestamp();

    // Prefill phase (process prompt)
    try batch.decode(ctx);
    const prefill_time = std.time.milliTimestamp() - gen_start;

    // Decode phase (generate tokens)
    const decode_start = std.time.milliTimestamp();

    for (0..args.max_tokens) |_| {
        const token = sampler.sample(ctx, -1);
        if (vocab.isEog(token)) break;

        generated_tokens += 1;

        // Stream the token
        const text = try detokenizer.detokenize(vocab, token);
        std.debug.print("{s}", .{text});
        detokenizer.clearRetainingCapacity();

        // Prepare next batch
        batch_token[0] = token;
        batch = llama.Batch.initOne(batch_token[0..]);
        try batch.decode(ctx);
    }

    const decode_time = std.time.milliTimestamp() - decode_start;
    const total_time = std.time.milliTimestamp() - gen_start;

    std.debug.print("\n\n", .{});

    // Show statistics
    if (args.show_stats) {
        std.debug.print("---\n", .{});
        std.debug.print("Statistics:\n", .{});
        std.debug.print("  Prompt tokens:    {d}\n", .{prompt_tokens});
        std.debug.print("  Generated tokens: {d}\n", .{generated_tokens});
        std.debug.print("  Prefill time:     {d:.2}ms ({d:.2} tokens/sec)\n", .{
            @as(f64, @floatFromInt(prefill_time)),
            @as(f64, @floatFromInt(prompt_tokens)) / (@as(f64, @floatFromInt(prefill_time)) / 1000.0),
        });
        std.debug.print("  Decode time:      {d:.2}ms ({d:.2} tokens/sec)\n", .{
            @as(f64, @floatFromInt(decode_time)),
            @as(f64, @floatFromInt(generated_tokens)) / (@as(f64, @floatFromInt(decode_time)) / 1000.0),
        });
        std.debug.print("  Total time:       {d:.2}ms\n", .{@as(f64, @floatFromInt(total_time))});
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() != .ok) @panic("memory leak detected");
    const alloc = gpa.allocator();

    const args_raw = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args_raw);

    const maybe_args = arg_utils.parseArgs(Args, args_raw[1..]) catch |err| {
        slog.err("Could not parse arguments: {}", .{err});
        arg_utils.printHelp(Args);
        return err;
    };

    const args = maybe_args orelse {
        arg_utils.printHelp(Args);
        return;
    };

    try run(alloc, args);
}

pub const std_options = std.Options{
    .log_level = std.log.Level.info,
};
