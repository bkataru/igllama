const std = @import("std");
const llama = @import("llama");
const config = @import("../config.zig");

/// Read a line from a file until newline or EOF
fn readLine(file: std.fs.File, buffer: []u8) !?[]u8 {
    var index: usize = 0;
    while (index < buffer.len) {
        const bytes_read = file.read(buffer[index .. index + 1]) catch |err| {
            if (index > 0) return buffer[0..index];
            return err;
        };
        if (bytes_read == 0) {
            if (index > 0) return buffer[0..index];
            return null; // EOF
        }
        if (buffer[index] == '\n') {
            return buffer[0..index];
        }
        index += 1;
    }
    return buffer[0..index];
}

/// Chat message role
const Role = enum {
    system,
    user,
    assistant,
};

/// A single message in the conversation
const Message = struct {
    role: Role,
    content: []const u8,
};

/// Chat session state
const ChatSession = struct {
    allocator: std.mem.Allocator,
    messages: std.ArrayList(Message),
    system_prompt: []const u8,

    pub fn init(allocator: std.mem.Allocator, system_prompt: []const u8) ChatSession {
        return .{
            .allocator = allocator,
            .messages = .empty,
            .system_prompt = system_prompt,
        };
    }

    pub fn deinit(self: *ChatSession) void {
        for (self.messages.items) |msg| {
            self.allocator.free(msg.content);
        }
        self.messages.deinit(self.allocator);
    }

    pub fn addMessage(self: *ChatSession, role: Role, content: []const u8) !void {
        const content_copy = try self.allocator.dupe(u8, content);
        try self.messages.append(self.allocator, .{ .role = role, .content = content_copy });
    }

    /// Format conversation using ChatML template
    /// <|im_start|>system\n{system}<|im_end|>\n<|im_start|>user\n{user}<|im_end|>\n<|im_start|>assistant\n
    pub fn formatChatML(self: *ChatSession, allocator: std.mem.Allocator) ![]const u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);

        // System message
        if (self.system_prompt.len > 0) {
            try result.appendSlice(allocator, "<|im_start|>system\n");
            try result.appendSlice(allocator, self.system_prompt);
            try result.appendSlice(allocator, "<|im_end|>\n");
        }

        // Conversation history
        for (self.messages.items) |msg| {
            try result.appendSlice(allocator, "<|im_start|>");
            try result.appendSlice(allocator, switch (msg.role) {
                .system => "system",
                .user => "user",
                .assistant => "assistant",
            });
            try result.appendSlice(allocator, "\n");
            try result.appendSlice(allocator, msg.content);
            try result.appendSlice(allocator, "<|im_end|>\n");
        }

        // Prompt for assistant response
        try result.appendSlice(allocator, "<|im_start|>assistant\n");

        return result.toOwnedSlice(allocator);
    }

    /// Format conversation using Llama 3 template
    pub fn formatLlama3(self: *ChatSession, allocator: std.mem.Allocator) ![]const u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);

        try result.appendSlice(allocator, "<|begin_of_text|>");

        // System message
        if (self.system_prompt.len > 0) {
            try result.appendSlice(allocator, "<|start_header_id|>system<|end_header_id|>\n\n");
            try result.appendSlice(allocator, self.system_prompt);
            try result.appendSlice(allocator, "<|eot_id|>");
        }

        // Conversation history
        for (self.messages.items) |msg| {
            try result.appendSlice(allocator, "<|start_header_id|>");
            try result.appendSlice(allocator, switch (msg.role) {
                .system => "system",
                .user => "user",
                .assistant => "assistant",
            });
            try result.appendSlice(allocator, "<|end_header_id|>\n\n");
            try result.appendSlice(allocator, msg.content);
            try result.appendSlice(allocator, "<|eot_id|>");
        }

        // Prompt for assistant response
        try result.appendSlice(allocator, "<|start_header_id|>assistant<|end_header_id|>\n\n");

        return result.toOwnedSlice(allocator);
    }
};

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
    var gpu_layers: i32 = 0;
    var max_tokens: usize = 2048;
    var system_prompt: []const u8 = "You are a helpful assistant.";
    var template: []const u8 = "chatml";

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--model") or std.mem.eql(u8, arg, "-m")) {
            if (i + 1 < args.len) {
                const path_z = try allocator.allocSentinel(u8, args[i + 1].len, 0);
                @memcpy(path_z, args[i + 1]);
                model_path = path_z;
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--gpu-layers") or std.mem.eql(u8, arg, "-ngl")) {
            if (i + 1 < args.len) {
                gpu_layers = std.fmt.parseInt(i32, args[i + 1], 10) catch 0;
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--max-tokens") or std.mem.eql(u8, arg, "-n")) {
            if (i + 1 < args.len) {
                max_tokens = std.fmt.parseInt(usize, args[i + 1], 10) catch 2048;
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--system") or std.mem.eql(u8, arg, "-s")) {
            if (i + 1 < args.len) {
                system_prompt = args[i + 1];
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--template") or std.mem.eql(u8, arg, "-t")) {
            if (i + 1 < args.len) {
                template = args[i + 1];
                i += 1;
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            const path_z = try allocator.allocSentinel(u8, arg.len, 0);
            @memcpy(path_z, arg);
            model_path = path_z;
        }
    }

    if (model_path == null) {
        try stderr.print("Error: Missing model path\n", .{});
        try stderr.print("Usage: igllama chat <model.gguf> [options]\n", .{});
        try stderr.print("\nOptions:\n", .{});
        try stderr.print("  -m, --model <path>       Model file path\n", .{});
        try stderr.print("  -s, --system <prompt>    System prompt (default: helpful assistant)\n", .{});
        try stderr.print("  -t, --template <name>    Chat template: chatml, llama3 (default: chatml)\n", .{});
        try stderr.print("  -n, --max-tokens <n>     Max tokens per response (default: 2048)\n", .{});
        try stderr.print("  -ngl, --gpu-layers <n>   GPU layers to offload (default: 0)\n", .{});
        try stderr.print("\nCommands during chat:\n", .{});
        try stderr.print("  /quit, /exit             Exit chat\n", .{});
        try stderr.print("  /clear                   Clear conversation history\n", .{});
        try stderr.print("  /system <prompt>         Change system prompt\n", .{});
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

    const vocab = model.vocab() orelse {
        try stderr.print("Error: Model missing vocabulary\n", .{});
        return error.MissingVocabulary;
    };

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

    // Initialize chat session
    var session = ChatSession.init(allocator, system_prompt);
    defer session.deinit();

    try stdout.print("\n{s} v{s} - Interactive Chat\n", .{ config.app_name, config.version });
    try stdout.print("Model: {s}\n", .{model_path.?});
    try stdout.print("Template: {s}\n", .{template});
    try stdout.print("Type /quit to exit, /clear to reset history\n\n", .{});
    try stdout.flush();

    // Read input buffer
    var input_buffer: [4096]u8 = undefined;
    const stdin_file = std.fs.File.stdin();

    // Main chat loop
    while (true) {
        // Print prompt
        try stdout.print("You: ", .{});
        try stdout.flush();

        // Read user input - read line from stdin
        const line = readLine(stdin_file, &input_buffer) catch |err| {
            try stderr.print("\nError reading input: {}\n", .{err});
            break;
        };

        if (line == null) {
            try stdout.print("\n", .{});
            break;
        }

        var user_input = std.mem.trim(u8, line.?, &[_]u8{ '\r', '\n', ' ', '\t' });

        if (user_input.len == 0) continue;

        // Handle commands
        if (std.mem.startsWith(u8, user_input, "/")) {
            if (std.mem.eql(u8, user_input, "/quit") or std.mem.eql(u8, user_input, "/exit")) {
                try stdout.print("Goodbye!\n", .{});
                break;
            } else if (std.mem.eql(u8, user_input, "/clear")) {
                for (session.messages.items) |msg| {
                    session.allocator.free(msg.content);
                }
                session.messages.clearRetainingCapacity();
                try stdout.print("Conversation cleared.\n\n", .{});
                continue;
            } else if (std.mem.startsWith(u8, user_input, "/system ")) {
                session.system_prompt = user_input[8..];
                try stdout.print("System prompt updated.\n\n", .{});
                continue;
            } else {
                try stdout.print("Unknown command: {s}\n", .{user_input});
                try stdout.print("Available: /quit, /clear, /system <prompt>\n\n", .{});
                continue;
            }
        }

        // Add user message to history
        try session.addMessage(.user, user_input);

        // Format prompt with chat template
        const formatted_prompt = if (std.mem.eql(u8, template, "llama3"))
            try session.formatLlama3(allocator)
        else
            try session.formatChatML(allocator);
        defer allocator.free(formatted_prompt);

        // Tokenize
        var tokenizer = llama.Tokenizer.init(allocator);
        defer tokenizer.deinit();
        try tokenizer.tokenize(vocab, formatted_prompt, false, true);

        // Check context length
        const ctx_limit: usize = @intCast(n_ctx_train);
        if (tokenizer.getTokens().len > ctx_limit - max_tokens) {
            try stderr.print("Warning: Conversation too long, clearing old messages\n", .{});
            // Keep only the last few messages
            while (session.messages.items.len > 2) {
                const msg = session.messages.orderedRemove(0);
                session.allocator.free(msg.content);
            }
            continue;
        }

        // Setup sampler
        var sampler = llama.Sampler.initChain(.{ .no_perf = false });
        defer sampler.deinit();
        sampler.add(llama.Sampler.initGreedy());

        var detokenizer = llama.Detokenizer.init(allocator);
        defer detokenizer.deinit();

        // Print assistant prefix
        try stdout.print("Assistant: ", .{});
        try stdout.flush();

        // Generate response
        var response_buffer: std.ArrayList(u8) = .empty;
        defer response_buffer.deinit(allocator);

        var batch = llama.Batch.initOne(tokenizer.getTokens());
        var batch_token: [1]llama.Token = undefined;

        for (0..max_tokens) |_| {
            try batch.decode(ctx);
            const token = sampler.sample(ctx, -1);
            if (vocab.isEog(token)) break;

            batch_token[0] = token;
            batch = llama.Batch.initOne(batch_token[0..]);

            // Get token text
            const token_text = try detokenizer.detokenize(vocab, token);
            try response_buffer.appendSlice(allocator, token_text);

            // Print token
            try stdout.print("{s}", .{token_text});
            try stdout.flush();
            detokenizer.clearRetainingCapacity();
        }

        try stdout.print("\n\n", .{});
        try stdout.flush();

        // Add assistant response to history
        if (response_buffer.items.len > 0) {
            try session.addMessage(.assistant, response_buffer.items);
        }

        // Note: In the new llama.cpp API, memory management has changed
        // The KV cache is now handled internally via llama_memory_t
        // For multi-turn conversation, we may need to update the bindings
    }
}
