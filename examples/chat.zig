const std = @import("std");
const llama = @import("llama");
const slog = std.log.scoped(.chat);
const arg_utils = @import("utils/args.zig");

const Model = llama.Model;
const Context = llama.Context;
const Token = llama.Token;

/// Multi-turn chat example demonstrating conversation history management.
/// This example shows how to:
/// - Maintain conversation history across turns
/// - Apply chat templates for proper formatting
/// - Handle user input in a loop
pub const Args = struct {
    model_path: [:0]const u8 = "models/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf",
    system_prompt: ?[]const u8 = "You are a helpful assistant.",
    max_tokens: usize = 256,
    context_size: ?u32 = null,
    seed: ?u32 = null,
    threads: ?usize = null,
    gpu_layers: i32 = 0,
    temperature: f32 = 0.7,
    top_p: f32 = 0.9,
    top_k: i32 = 40,
};

const Message = struct {
    role: []const u8,
    content: []const u8,
};

pub fn run(alloc: std.mem.Allocator, args: Args) !void {
    llama.Backend.init();
    defer llama.Backend.deinit();

    // Suppress verbose logging
    llama.logSet(null, null);

    var mparams = Model.defaultParams();
    mparams.n_gpu_layers = args.gpu_layers;
    const model = try Model.initFromFile(args.model_path.ptr, mparams);
    defer model.deinit();

    var cparams = Context.defaultParams();
    const n_ctx_train = model.nCtxTrain();
    cparams.n_ctx = args.context_size orelse @intCast(n_ctx_train);

    const cpu_threads = try std.Thread.getCpuCount();
    cparams.n_threads = @intCast(args.threads orelse @min(cpu_threads, 4));
    cparams.n_threads_batch = @intCast(cpu_threads / 2);
    cparams.no_perf = true;

    const ctx = try Context.initWithModel(model, cparams);
    defer ctx.deinit();

    // Setup sampler chain
    var sampler = llama.Sampler.initChain(.{ .no_perf = true });
    defer sampler.deinit();

    // Add sampling steps in correct order
    sampler.add(llama.Sampler.initTopK(args.top_k));
    sampler.add(llama.Sampler.initTopP(args.top_p, 1));
    sampler.add(llama.Sampler.initTemp(args.temperature));
    sampler.add(llama.Sampler.initDist(args.seed orelse @truncate(@as(u64, @bitCast(std.time.milliTimestamp())))));

    const vocab = model.vocab() orelse @panic("model missing vocab!");

    // Conversation history - use dynamic array
    var history_items: [100]Message = undefined;
    var history_len: usize = 0;
    var history_owned: [100][]u8 = undefined; // track owned content for cleanup
    var owned_count: usize = 0;

    defer {
        for (0..owned_count) |i| {
            alloc.free(history_owned[i]);
        }
    }

    // Add system prompt if provided
    if (args.system_prompt) |sys| {
        const content_copy = try alloc.dupe(u8, sys);
        history_owned[owned_count] = content_copy;
        owned_count += 1;
        history_items[history_len] = .{
            .role = "system",
            .content = content_copy,
        };
        history_len += 1;
    }

    std.debug.print("Chat started. Type 'quit' or 'exit' to end.\n", .{});
    std.debug.print("Model: {s}\n", .{args.model_path});
    std.debug.print("---\n", .{});

    var input_buf: [4096]u8 = undefined;
    const stdin = std.fs.File.stdin();
    // Using deprecatedReader() for Zig 0.15 compatibility - the new reader() API requires
    // passing a buffer parameter which changes the usage pattern. deprecatedReader() provides
    // the familiar unbuffered reader interface. This can be updated when Zig stabilizes the API.
    const reader = stdin.deprecatedReader();

    while (true) {
        std.debug.print("\nYou: ", .{});

        const input = reader.readUntilDelimiter(&input_buf, '\n') catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };

        const trimmed = std.mem.trim(u8, input, " \t\r\n");
        if (trimmed.len == 0) continue;

        if (std.mem.eql(u8, trimmed, "quit") or std.mem.eql(u8, trimmed, "exit")) {
            std.debug.print("Goodbye!\n", .{});
            break;
        }

        // Add user message to history
        const user_content = try alloc.dupe(u8, trimmed);
        history_owned[owned_count] = user_content;
        owned_count += 1;
        history_items[history_len] = .{
            .role = "user",
            .content = user_content,
        };
        history_len += 1;

        // Format conversation with chat template
        // For simplicity, using ChatML format: <|im_start|>role\ncontent<|im_end|>
        var prompt_list: std.ArrayListUnmanaged(u8) = .{};
        defer prompt_list.deinit(alloc);

        for (history_items[0..history_len]) |msg| {
            try prompt_list.appendSlice(alloc, "<|im_start|>");
            try prompt_list.appendSlice(alloc, msg.role);
            try prompt_list.append(alloc, '\n');
            try prompt_list.appendSlice(alloc, msg.content);
            try prompt_list.appendSlice(alloc, "<|im_end|>\n");
        }
        try prompt_list.appendSlice(alloc, "<|im_start|>assistant\n");

        // Tokenize
        var tokenizer = llama.Tokenizer.init(alloc);
        defer tokenizer.deinit();
        try tokenizer.tokenize(vocab, prompt_list.items, false, true);

        // Generate response
        std.debug.print("Assistant: ", .{});

        var response_list: std.ArrayListUnmanaged(u8) = .{};
        defer response_list.deinit(alloc);

        var detokenizer = llama.Detokenizer.init(alloc);
        defer detokenizer.deinit();

        var batch = llama.Batch.initOne(tokenizer.getTokens());
        var batch_token: [1]Token = undefined;

        for (0..args.max_tokens) |_| {
            try batch.decode(ctx);
            const token = sampler.sample(ctx, -1);
            if (vocab.isEog(token)) break;

            const text = try detokenizer.detokenize(vocab, token);
            if (std.mem.indexOf(u8, text, "<|im_end|>") != null) break;

            std.debug.print("{s}", .{text});
            try response_list.appendSlice(alloc, text);
            detokenizer.clearRetainingCapacity();

            batch_token[0] = token;
            batch = llama.Batch.initOne(batch_token[0..]);
        }
        std.debug.print("\n", .{});

        // Add assistant response to history
        if (response_list.items.len > 0) {
            const assistant_content = try alloc.dupe(u8, response_list.items);
            history_owned[owned_count] = assistant_content;
            owned_count += 1;
            history_items[history_len] = .{
                .role = "assistant",
                .content = assistant_content,
            };
            history_len += 1;
        }

        // Reset context for next turn (simple approach)
        if (ctx.getMemory()) |mem| {
            mem.clear(false);
        }
        sampler.reset();
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
