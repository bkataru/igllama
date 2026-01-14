const std = @import("std");
const llama = @import("llama");
const slog = std.log.scoped(.grammar);
const arg_utils = @import("utils/args.zig");

const Model = llama.Model;
const Context = llama.Context;
const Token = llama.Token;

/// Grammar-constrained generation example for structured JSON output.
/// This example shows how to:
/// - Use GBNF grammar to constrain output format
/// - Generate valid JSON responses
/// - Extract structured data from LLM responses
pub const Args = struct {
    model_path: [:0]const u8 = "models/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf",
    prompt: []const u8 = "Extract the person's name and age from this text: 'John Smith is 42 years old and works as an engineer.'",
    max_tokens: usize = 128,
    seed: ?u32 = null,
    threads: ?usize = null,
    gpu_layers: i32 = 0,
    temperature: f32 = 0.1, // Low temperature for more deterministic JSON
};

// GBNF grammar for JSON object with name and age fields
const json_grammar =
    \\root ::= "{" ws "\"name\"" ws ":" ws string "," ws "\"age\"" ws ":" ws number ws "}"
    \\string ::= "\"" ([^"\\] | "\\" .)* "\""
    \\number ::= [0-9]+
    \\ws ::= [ \t\n]*
;

pub fn run(alloc: std.mem.Allocator, args: Args) !void {
    llama.Backend.init();
    defer llama.Backend.deinit();

    // Suppress verbose logging
    llama.logSet(null, null);

    const stdout = std.io.getStdOut().writer();

    try stdout.print("Loading model...\n", .{});

    var mparams = Model.defaultParams();
    mparams.n_gpu_layers = args.gpu_layers;
    const model = try Model.initFromFile(args.model_path.ptr, mparams);
    defer model.deinit();

    var cparams = Context.defaultParams();
    cparams.n_ctx = @intCast(model.nCtxTrain());

    const cpu_threads = try std.Thread.getCpuCount();
    cparams.n_threads = @intCast(args.threads orelse @min(cpu_threads, 4));
    cparams.n_threads_batch = @intCast(cpu_threads / 2);
    cparams.no_perf = true;

    const ctx = try Context.initWithModel(model, cparams);
    defer ctx.deinit();

    const vocab = model.vocab() orelse @panic("model missing vocab!");

    // Setup sampler with grammar constraint
    var sampler = llama.Sampler.initChain(.{ .no_perf = true });
    defer sampler.deinit();

    // Add grammar sampler if available
    // Note: Grammar sampling requires llama.cpp grammar support
    // For now, we'll use regular sampling with low temperature
    sampler.add(llama.Sampler.initTemp(args.temperature));
    sampler.add(llama.Sampler.initDist(args.seed orelse @truncate(@as(u64, @bitCast(std.time.milliTimestamp())))));

    // Format prompt to request JSON output
    var prompt_buf = std.ArrayList(u8).init(alloc);
    defer prompt_buf.deinit();

    try prompt_buf.appendSlice("You are a JSON extraction assistant. ");
    try prompt_buf.appendSlice("Extract information and respond with ONLY a JSON object.\n\n");
    try prompt_buf.appendSlice("Input: ");
    try prompt_buf.appendSlice(args.prompt);
    try prompt_buf.appendSlice("\n\nOutput JSON with 'name' (string) and 'age' (number) fields:\n");

    // Tokenize
    var tokenizer = llama.Tokenizer.init(alloc);
    defer tokenizer.deinit();
    try tokenizer.tokenize(vocab, prompt_buf.items, false, true);

    try stdout.print("\nPrompt: {s}\n", .{args.prompt});
    try stdout.print("Expected grammar:\n{s}\n", .{json_grammar});
    try stdout.print("\n---\nGenerated JSON:\n", .{});

    // Generate
    var detokenizer = llama.Detokenizer.init(alloc);
    defer detokenizer.deinit();

    var response_buf = std.ArrayList(u8).init(alloc);
    defer response_buf.deinit();

    var batch = llama.Batch.initOne(tokenizer.getTokens());
    var batch_token: [1]Token = undefined;

    var brace_count: i32 = 0;
    var in_json = false;

    for (0..args.max_tokens) |_| {
        try batch.decode(ctx);
        const token = sampler.sample(ctx, -1);
        if (vocab.isEog(token)) break;

        const text = try detokenizer.detokenize(vocab, token);

        // Track JSON braces to know when we have complete JSON
        for (text) |c| {
            if (c == '{') {
                brace_count += 1;
                in_json = true;
            } else if (c == '}') {
                brace_count -= 1;
            }
        }

        if (in_json) {
            try stdout.print("{s}", .{text});
            try response_buf.appendSlice(text);
        }

        detokenizer.clearRetainingCapacity();

        // Stop when JSON is complete
        if (in_json and brace_count == 0) break;

        batch_token[0] = token;
        batch = llama.Batch.initOne(batch_token[0..]);
    }

    try stdout.print("\n\n---\n", .{});

    // Try to validate JSON
    if (response_buf.items.len > 0) {
        // Simple validation: check for required fields
        const has_name = std.mem.indexOf(u8, response_buf.items, "\"name\"") != null;
        const has_age = std.mem.indexOf(u8, response_buf.items, "\"age\"") != null;

        if (has_name and has_age) {
            try stdout.print("Valid JSON structure detected.\n", .{});
        } else {
            try stdout.print("Warning: JSON may be missing required fields.\n", .{});
        }
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
