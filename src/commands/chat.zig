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

/// Check if stdin is a TTY (interactive terminal)
fn isStdinTty() bool {
    const stdin_file = std.fs.File.stdin();
    // On Windows and Unix, use std.fs.File.isTty() which handles both
    return stdin_file.isTty();
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

/// Result from JSON string parsing
const JsonStringResult = struct {
    value: []const u8,
    end_pos: usize,
};

/// Write a string with JSON escaping to an ArrayList
fn appendJsonEscaped(list: *std.ArrayList(u8), allocator: std.mem.Allocator, str: []const u8) !void {
    for (str) |c| {
        switch (c) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            else => try list.append(allocator, c),
        }
    }
}

/// Find and extract a JSON string value starting near pos
fn findJsonString(content: []const u8, start_pos: usize) ?JsonStringResult {
    // Find opening quote
    var pos = start_pos;
    while (pos < content.len and content[pos] != '"') : (pos += 1) {}
    if (pos >= content.len) return null;
    pos += 1; // skip opening quote

    const str_start = pos;
    var str_end = pos;

    // Find closing quote (handling escapes)
    while (str_end < content.len) {
        if (content[str_end] == '\\' and str_end + 1 < content.len) {
            str_end += 2; // skip escaped char
        } else if (content[str_end] == '"') {
            break;
        } else {
            str_end += 1;
        }
    }

    if (str_end >= content.len) return null;

    return .{
        .value = content[str_start..str_end],
        .end_pos = str_end + 1,
    };
}

/// Chat session state
const ChatSession = struct {
    allocator: std.mem.Allocator,
    messages: std.ArrayList(Message),
    system_prompt: []const u8,
    system_prompt_owned: bool = false,

    pub fn init(allocator: std.mem.Allocator, system_prompt: []const u8) ChatSession {
        return .{
            .allocator = allocator,
            .messages = .empty,
            .system_prompt = system_prompt,
            .system_prompt_owned = false,
        };
    }

    pub fn deinit(self: *ChatSession) void {
        for (self.messages.items) |msg| {
            self.allocator.free(msg.content);
        }
        self.messages.deinit(self.allocator);
        if (self.system_prompt_owned) {
            self.allocator.free(@constCast(self.system_prompt));
        }
    }

    pub fn addMessage(self: *ChatSession, role: Role, content: []const u8) !void {
        const content_copy = try self.allocator.dupe(u8, content);
        try self.messages.append(self.allocator, .{ .role = role, .content = content_copy });
    }

    /// Save conversation history to a JSON file
    pub fn saveToFile(self: *ChatSession, filepath: []const u8) !void {
        var file = try std.fs.cwd().createFile(filepath, .{});
        defer file.close();

        // Build the JSON content in memory first
        var content: std.ArrayList(u8) = .empty;
        defer content.deinit(self.allocator);

        // Write JSON manually (simple format)
        try content.appendSlice(self.allocator, "{\n");
        try content.appendSlice(self.allocator, "  \"system_prompt\": \"");
        try appendJsonEscaped(&content, self.allocator, self.system_prompt);
        try content.appendSlice(self.allocator, "\",\n");
        try content.appendSlice(self.allocator, "  \"messages\": [\n");

        for (self.messages.items, 0..) |msg, idx| {
            try content.appendSlice(self.allocator, "    {\n");
            try content.appendSlice(self.allocator, "      \"role\": \"");
            try content.appendSlice(self.allocator, switch (msg.role) {
                .system => "system",
                .user => "user",
                .assistant => "assistant",
            });
            try content.appendSlice(self.allocator, "\",\n");
            try content.appendSlice(self.allocator, "      \"content\": \"");
            try appendJsonEscaped(&content, self.allocator, msg.content);
            try content.appendSlice(self.allocator, "\"\n");
            try content.appendSlice(self.allocator, "    }");
            if (idx < self.messages.items.len - 1) {
                try content.appendSlice(self.allocator, ",");
            }
            try content.appendSlice(self.allocator, "\n");
        }

        try content.appendSlice(self.allocator, "  ]\n");
        try content.appendSlice(self.allocator, "}\n");

        // Write all at once
        try file.writeAll(content.items);
    }

    /// Load conversation history from a JSON file
    pub fn loadFromFile(self: *ChatSession, filepath: []const u8) !void {
        const file = std.fs.cwd().openFile(filepath, .{}) catch |err| {
            return err;
        };
        defer file.close();

        // Read entire file
        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024); // 1MB max
        defer self.allocator.free(content);

        // Clear existing messages
        for (self.messages.items) |msg| {
            self.allocator.free(msg.content);
        }
        self.messages.clearRetainingCapacity();

        // Simple JSON parsing (not a full parser, handles our format)
        var pos: usize = 0;

        // Find system_prompt
        if (std.mem.indexOf(u8, content, "\"system_prompt\":")) |sp_start| {
            pos = sp_start + 16;
            if (findJsonString(content, pos)) |result| {
                // Free old system prompt if owned
                if (self.system_prompt_owned) {
                    self.allocator.free(@constCast(self.system_prompt));
                }
                self.system_prompt = try self.allocator.dupe(u8, result.value);
                self.system_prompt_owned = true;
                pos = result.end_pos;
            }
        }

        // Find messages array
        if (std.mem.indexOf(u8, content[pos..], "\"messages\":")) |msg_start| {
            pos = pos + msg_start;

            // Parse each message
            while (std.mem.indexOf(u8, content[pos..], "\"role\":")) |role_start| {
                const role_pos = pos + role_start + 7;

                var role: Role = .user;
                if (findJsonString(content, role_pos)) |role_result| {
                    if (std.mem.eql(u8, role_result.value, "system")) {
                        role = .system;
                    } else if (std.mem.eql(u8, role_result.value, "assistant")) {
                        role = .assistant;
                    }
                    pos = role_result.end_pos;
                } else break;

                // Find content
                if (std.mem.indexOf(u8, content[pos..], "\"content\":")) |content_start| {
                    const content_pos = pos + content_start + 10;
                    if (findJsonString(content, content_pos)) |content_result| {
                        try self.addMessage(role, content_result.value);
                        pos = content_result.end_pos;
                    } else break;
                } else break;
            }
        }
    }

    /// Get message count
    pub fn messageCount(self: *ChatSession) usize {
        return self.messages.items.len;
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

    /// Format conversation using Mistral template
    pub fn formatMistral(self: *ChatSession, allocator: std.mem.Allocator) ![]const u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);

        // System message (if present, add as first user message)
        if (self.system_prompt.len > 0) {
            try result.appendSlice(allocator, "<s>[INST] ");
            try result.appendSlice(allocator, self.system_prompt);
            try result.appendSlice(allocator, " [/INST]");
        }

        // Conversation history
        for (self.messages.items) |msg| {
            switch (msg.role) {
                .user => {
                    try result.appendSlice(allocator, "[INST] ");
                    try result.appendSlice(allocator, msg.content);
                    try result.appendSlice(allocator, " [/INST]");
                },
                .assistant => {
                    try result.appendSlice(allocator, " ");
                    try result.appendSlice(allocator, msg.content);
                    try result.appendSlice(allocator, "</s>");
                },
                .system => {
                    // Mistral doesn't have separate system tokens, include as user message
                    try result.appendSlice(allocator, "[INST] ");
                    try result.appendSlice(allocator, msg.content);
                    try result.appendSlice(allocator, " [/INST]");
                },
            }
        }

        return result.toOwnedSlice(allocator);
    }

    /// Format conversation using Gemma template
    pub fn formatGemma(self: *ChatSession, allocator: std.mem.Allocator) ![]const u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);

        try result.appendSlice(allocator, "<bos>");

        // System message (add as first user message)
        if (self.system_prompt.len > 0) {
            try result.appendSlice(allocator, "<start_of_turn>user\n");
            try result.appendSlice(allocator, self.system_prompt);
            try result.appendSlice(allocator, "<end_of_turn>\n");
            try result.appendSlice(allocator, "<start_of_turn>model\n");
            try result.appendSlice(allocator, "I understand. I'm ready to help!");
            try result.appendSlice(allocator, "<end_of_turn>\n");
        }

        // Conversation history
        for (self.messages.items) |msg| {
            try result.appendSlice(allocator, "<start_of_turn>");
            try result.appendSlice(allocator, switch (msg.role) {
                .user => "user",
                .assistant => "model",
                .system => "user", // Gemma treats system as user
            });
            try result.appendSlice(allocator, "\n");
            try result.appendSlice(allocator, msg.content);
            try result.appendSlice(allocator, "<end_of_turn>\n");
        }

        // Prompt for assistant response
        try result.appendSlice(allocator, "<start_of_turn>model\n");

        return result.toOwnedSlice(allocator);
    }

    /// Format conversation using Phi-3 template
    pub fn formatPhi3(self: *ChatSession, allocator: std.mem.Allocator) ![]const u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);

        try result.appendSlice(allocator, "<s>");

        // System message
        if (self.system_prompt.len > 0) {
            try result.appendSlice(allocator, "<|system|>\n");
            try result.appendSlice(allocator, self.system_prompt);
            try result.appendSlice(allocator, "<|end|>\n");
        }

        // Conversation history
        for (self.messages.items) |msg| {
            try result.appendSlice(allocator, "<|");
            try result.appendSlice(allocator, switch (msg.role) {
                .user => "user",
                .assistant => "assistant",
                .system => "system",
            });
            try result.appendSlice(allocator, "|>\n");
            try result.appendSlice(allocator, msg.content);
            try result.appendSlice(allocator, "<|end|>\n");
        }

        // Prompt for assistant response
        try result.appendSlice(allocator, "<|assistant|>\n");

        return result.toOwnedSlice(allocator);
    }

    /// Format conversation using Qwen template
    pub fn formatQwen(self: *ChatSession, allocator: std.mem.Allocator) ![]const u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);

        try result.appendSlice(allocator, "<|im_start|>system\n");
        try result.appendSlice(allocator, self.system_prompt);
        try result.appendSlice(allocator, "<|im_end|>\n");

        // Conversation history
        for (self.messages.items) |msg| {
            try result.appendSlice(allocator, "<|im_start|>");
            try result.appendSlice(allocator, switch (msg.role) {
                .user => "user",
                .assistant => "assistant",
                .system => "system",
            });
            try result.appendSlice(allocator, "\n");
            try result.appendSlice(allocator, msg.content);
            try result.appendSlice(allocator, "<|im_end|>\n");
        }

        // Prompt for assistant response
        try result.appendSlice(allocator, "<|im_start|>assistant\n");

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
    var context_size: ?u32 = null; // Override context size (null = use model default)
    var seed: u32 = 0; // 0 = random seed
    var quiet_mode: bool = false; // Suppress model loading logs
    var temperature: f32 = 0.7; // Sampling temperature
    var top_p: f32 = 0.9; // Top-p (nucleus) sampling
    var top_k: i32 = 40; // Top-k sampling
    var repeat_penalty: f32 = 1.1; // Repetition penalty
    var single_prompt: ?[]const u8 = null; // Single-turn mode prompt
    var json_output: bool = false; // JSON output mode

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
        } else if (std.mem.eql(u8, arg, "--context-size") or std.mem.eql(u8, arg, "-c")) {
            if (i + 1 < args.len) {
                context_size = std.fmt.parseInt(u32, args[i + 1], 10) catch null;
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--seed")) {
            if (i + 1 < args.len) {
                seed = std.fmt.parseInt(u32, args[i + 1], 10) catch 0;
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--temp") or std.mem.eql(u8, arg, "--temperature")) {
            if (i + 1 < args.len) {
                temperature = std.fmt.parseFloat(f32, args[i + 1]) catch 0.7;
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--top-p")) {
            if (i + 1 < args.len) {
                top_p = std.fmt.parseFloat(f32, args[i + 1]) catch 0.9;
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--top-k")) {
            if (i + 1 < args.len) {
                top_k = std.fmt.parseInt(i32, args[i + 1], 10) catch 40;
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--repeat-penalty")) {
            if (i + 1 < args.len) {
                repeat_penalty = std.fmt.parseFloat(f32, args[i + 1]) catch 1.1;
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            quiet_mode = true;
        } else if (std.mem.eql(u8, arg, "--prompt") or std.mem.eql(u8, arg, "-p")) {
            if (i + 1 < args.len) {
                single_prompt = args[i + 1];
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--json")) {
            json_output = true;
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
        try stderr.print("  -c, --context-size <n>   Context size (default: model's training size)\n", .{});
        try stderr.print("  -n, --max-tokens <n>     Max tokens per response (default: 2048)\n", .{});
        try stderr.print("  -s, --system <prompt>    System prompt (default: helpful assistant)\n", .{});
        try stderr.print("  -t, --template <name>    Chat template: chatml, llama3, mistral, gemma, phi3, qwen\n", .{});
        try stderr.print("  -ngl, --gpu-layers <n>   GPU layers to offload (default: 0)\n", .{});
        try stderr.print("  -q, --quiet              Suppress model loading logs\n", .{});
        try stderr.print("  -p, --prompt <text>      Single-turn mode: generate response and exit\n", .{});
        try stderr.print("  --json                   Output response as JSON (for scripting)\n", .{});
        try stderr.print("\nSampling options:\n", .{});
        try stderr.print("  --temp <f>               Temperature (default: 0.7, 0=greedy)\n", .{});
        try stderr.print("  --top-p <f>              Top-p nucleus sampling (default: 0.9)\n", .{});
        try stderr.print("  --top-k <n>              Top-k sampling (default: 40)\n", .{});
        try stderr.print("  --repeat-penalty <f>     Repetition penalty (default: 1.1)\n", .{});
        try stderr.print("  --seed <n>               Random seed (default: 0=random)\n", .{});
        try stderr.print("\nCommands during chat:\n", .{});
        try stderr.print("  /quit, /exit             Exit chat\n", .{});
        try stderr.print("  /clear                   Clear conversation history\n", .{});
        try stderr.print("  /system <prompt>         Change system prompt\n", .{});
        try stderr.print("  /save <file>             Save conversation to file\n", .{});
        try stderr.print("  /load <file>             Load conversation from file\n", .{});
        try stderr.print("  /history                 Show conversation history\n", .{});
        try stderr.print("  /tokens                  Show token count of last exchange\n", .{});
        try stderr.print("  /stats                   Show generation statistics\n", .{});
        return error.InvalidArguments;
    }

    defer if (model_path) |p| allocator.free(p);

    if (!quiet_mode) {
        try stdout.print("Loading model: {s}\n", .{model_path.?});
        try stdout.flush();
    }

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
    const n_ctx_train: u32 = @intCast(model.nCtxTrain());

    // Use custom context size or model default
    const effective_ctx_size: u32 = if (context_size) |ctx_sz| blk: {
        if (ctx_sz > n_ctx_train) {
            try stderr.print("Warning: context-size {d} exceeds model's training size {d}, using {d}\n", .{ ctx_sz, n_ctx_train, n_ctx_train });
            break :blk n_ctx_train;
        }
        break :blk ctx_sz;
    } else n_ctx_train;

    cparams.n_ctx = effective_ctx_size;

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

    // Statistics tracking
    var last_prompt_tokens: usize = 0;
    var last_response_tokens: usize = 0;
    var total_prompt_tokens: usize = 0;
    var total_response_tokens: usize = 0;
    var last_generation_time_ns: i128 = 0;

    // Determine run mode: interactive, single-prompt, or piped
    const is_tty = isStdinTty();
    const is_interactive = is_tty and single_prompt == null;

    if (is_interactive and !quiet_mode) {
        try stdout.print("\n{s} v{s} - Interactive Chat\n", .{ config.app_name, config.version });
        try stdout.print("Model: {s}\n", .{model_path.?});
        try stdout.print("Template: {s} | Context: {d} tokens\n", .{ template, effective_ctx_size });
        if (temperature == 0) {
            try stdout.print("Sampling: greedy\n", .{});
        } else {
            try stdout.print("Sampling: temp={d:.2}, top_p={d:.2}, top_k={d}\n", .{ temperature, top_p, top_k });
        }
        try stdout.print("Type /quit to exit, /help for commands\n\n", .{});
    }
    try stdout.flush();

    // Read input buffer
    var input_buffer: [4096]u8 = undefined;
    const stdin_file = std.fs.File.stdin();

    // For piped input, read all of stdin at once
    var piped_input: ?[]u8 = null;
    defer if (piped_input) |p| allocator.free(p);

    if (!is_tty and single_prompt == null) {
        // Read all input from piped stdin
        piped_input = stdin_file.readToEndAlloc(allocator, 1024 * 1024) catch null; // 1MB max
    }

    // Main chat loop
    var first_iteration = true;
    while (true) {
        var user_input: []const u8 = undefined;

        // Get input based on mode
        if (single_prompt) |prompt| {
            // Single-turn mode: use the provided prompt
            if (!first_iteration) break; // Only run once
            user_input = prompt;
        } else if (piped_input) |input| {
            // Piped mode: use all piped input
            if (!first_iteration) break; // Only run once
            user_input = std.mem.trim(u8, input, &[_]u8{ '\r', '\n', ' ', '\t' });
        } else {
            // Interactive mode: read from terminal
            try stdout.print("You: ", .{});
            try stdout.flush();

            const line = readLine(stdin_file, &input_buffer) catch |err| {
                try stderr.print("\nError reading input: {}\n", .{err});
                break;
            };

            if (line == null) {
                try stdout.print("\n", .{});
                break;
            }

            user_input = std.mem.trim(u8, line.?, &[_]u8{ '\r', '\n', ' ', '\t' });
        }
        first_iteration = false;

        if (user_input.len == 0) continue;

        // Handle commands (only in interactive mode)
        if (is_interactive and std.mem.startsWith(u8, user_input, "/")) {
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
            } else if (std.mem.startsWith(u8, user_input, "/save ")) {
                const filepath = std.mem.trim(u8, user_input[6..], &[_]u8{ ' ', '\t' });
                if (filepath.len == 0) {
                    try stderr.print("Usage: /save <filename>\n\n", .{});
                } else {
                    session.saveToFile(filepath) catch |err| {
                        try stderr.print("Error saving: {}\n\n", .{err});
                        continue;
                    };
                    try stdout.print("Conversation saved to: {s}\n\n", .{filepath});
                }
                continue;
            } else if (std.mem.startsWith(u8, user_input, "/load ")) {
                const filepath = std.mem.trim(u8, user_input[6..], &[_]u8{ ' ', '\t' });
                if (filepath.len == 0) {
                    try stderr.print("Usage: /load <filename>\n\n", .{});
                } else {
                    session.loadFromFile(filepath) catch |err| {
                        try stderr.print("Error loading: {}\n\n", .{err});
                        continue;
                    };
                    try stdout.print("Loaded {d} messages from: {s}\n\n", .{ session.messageCount(), filepath });
                }
                continue;
            } else if (std.mem.eql(u8, user_input, "/history")) {
                try stdout.print("\n--- Conversation History ---\n", .{});
                try stdout.print("System: {s}\n\n", .{session.system_prompt});
                for (session.messages.items, 0..) |msg, idx| {
                    const role_str = switch (msg.role) {
                        .system => "System",
                        .user => "User",
                        .assistant => "Assistant",
                    };
                    try stdout.print("[{d}] {s}: {s}\n", .{ idx + 1, role_str, msg.content });
                }
                try stdout.print("--- End ({d} messages) ---\n\n", .{session.messageCount()});
                try stdout.flush();
                continue;
            } else if (std.mem.eql(u8, user_input, "/tokens")) {
                try stdout.print("\n--- Token Count ---\n", .{});
                try stdout.print("Last prompt:    {d} tokens\n", .{last_prompt_tokens});
                try stdout.print("Last response:  {d} tokens\n", .{last_response_tokens});
                try stdout.print("Total prompt:   {d} tokens\n", .{total_prompt_tokens});
                try stdout.print("Total response: {d} tokens\n", .{total_response_tokens});
                try stdout.print("Context used:   {d}/{d} tokens\n\n", .{ total_prompt_tokens + total_response_tokens, effective_ctx_size });
                continue;
            } else if (std.mem.eql(u8, user_input, "/stats")) {
                try stdout.print("\n--- Generation Statistics ---\n", .{});
                try stdout.print("Last prompt tokens:    {d}\n", .{last_prompt_tokens});
                try stdout.print("Last response tokens:  {d}\n", .{last_response_tokens});
                if (last_generation_time_ns > 0 and last_response_tokens > 0) {
                    const time_sec: f64 = @as(f64, @floatFromInt(last_generation_time_ns)) / 1_000_000_000.0;
                    const tokens_per_sec: f64 = @as(f64, @floatFromInt(last_response_tokens)) / time_sec;
                    try stdout.print("Last generation time:  {d:.2}s\n", .{time_sec});
                    try stdout.print("Tokens per second:     {d:.2}\n", .{tokens_per_sec});
                }
                try stdout.print("Total tokens:          {d} ({d} prompt + {d} response)\n", .{ total_prompt_tokens + total_response_tokens, total_prompt_tokens, total_response_tokens });
                try stdout.print("Context usage:         {d}/{d} ({d:.1}%)\n\n", .{ total_prompt_tokens + total_response_tokens, effective_ctx_size, @as(f64, @floatFromInt(total_prompt_tokens + total_response_tokens)) / @as(f64, @floatFromInt(effective_ctx_size)) * 100.0 });
                continue;
            } else if (std.mem.eql(u8, user_input, "/help")) {
                try stdout.print("\nCommands:\n", .{});
                try stdout.print("  /quit, /exit   Exit chat\n", .{});
                try stdout.print("  /clear         Clear conversation history\n", .{});
                try stdout.print("  /system <p>    Change system prompt\n", .{});
                try stdout.print("  /save <file>   Save conversation to file\n", .{});
                try stdout.print("  /load <file>   Load conversation from file\n", .{});
                try stdout.print("  /history       Show conversation history\n", .{});
                try stdout.print("  /tokens        Show token counts\n", .{});
                try stdout.print("  /stats         Show generation statistics\n", .{});
                try stdout.print("  /help          Show this help\n\n", .{});
                continue;
            } else {
                try stdout.print("Unknown command: {s}\n", .{user_input});
                try stdout.print("Type /help for available commands\n\n", .{});
                continue;
            }
        }

        // Add user message to history
        try session.addMessage(.user, user_input);

        // Format prompt with chat template
        const formatted_prompt = if (std.mem.eql(u8, template, "llama3"))
            try session.formatLlama3(allocator)
        else if (std.mem.eql(u8, template, "mistral"))
            try session.formatMistral(allocator)
        else if (std.mem.eql(u8, template, "gemma"))
            try session.formatGemma(allocator)
        else if (std.mem.eql(u8, template, "phi3"))
            try session.formatPhi3(allocator)
        else if (std.mem.eql(u8, template, "qwen"))
            try session.formatQwen(allocator)
        else
            try session.formatChatML(allocator);
        defer allocator.free(formatted_prompt);

        // Tokenize
        var tokenizer = llama.Tokenizer.init(allocator);
        defer tokenizer.deinit();
        try tokenizer.tokenize(vocab, formatted_prompt, false, true);

        // Track prompt tokens
        last_prompt_tokens = tokenizer.getTokens().len;
        total_prompt_tokens += last_prompt_tokens;

        // Check context length
        const ctx_limit: usize = @intCast(effective_ctx_size);
        if (tokenizer.getTokens().len > ctx_limit - max_tokens) {
            try stderr.print("Warning: Conversation too long, clearing old messages\n", .{});
            // Keep only the last few messages
            while (session.messages.items.len > 2) {
                const msg = session.messages.orderedRemove(0);
                session.allocator.free(msg.content);
            }
            continue;
        }

        // Setup sampler chain with configured parameters
        var sampler = llama.Sampler.initChain(.{ .no_perf = false });
        defer sampler.deinit();

        // Build sampling chain based on parameters
        if (temperature == 0) {
            // Greedy sampling (deterministic)
            sampler.add(llama.Sampler.initGreedy());
        } else {
            // Add repetition penalty if > 1.0
            if (repeat_penalty > 1.0) {
                sampler.add(llama.Sampler.initPenalties(64, repeat_penalty, 0.0, 0.0));
            }
            // Top-K sampling
            if (top_k > 0) {
                sampler.add(llama.Sampler.initTopK(top_k));
            }
            // Top-P (nucleus) sampling
            if (top_p < 1.0) {
                sampler.add(llama.Sampler.initTopP(top_p, 1));
            }
            // Temperature
            sampler.add(llama.Sampler.initTemp(temperature));
            // Distribution sampling with seed
            sampler.add(llama.Sampler.initDist(seed));
        }

        var detokenizer = llama.Detokenizer.init(allocator);
        defer detokenizer.deinit();

        // Print assistant prefix (only in interactive mode, not JSON)
        if (is_interactive and !json_output) {
            try stdout.print("Assistant: ", .{});
            try stdout.flush();
        }

        // Generate response with timing
        var response_buffer: std.ArrayList(u8) = .empty;
        defer response_buffer.deinit(allocator);

        const start_time = std.time.nanoTimestamp();
        var generated_tokens: usize = 0;

        var batch = llama.Batch.initOne(tokenizer.getTokens());
        var batch_token: [1]llama.Token = undefined;

        for (0..max_tokens) |_| {
            try batch.decode(ctx);
            const token = sampler.sample(ctx, -1);
            if (vocab.isEog(token)) break;

            batch_token[0] = token;
            batch = llama.Batch.initOne(batch_token[0..]);
            generated_tokens += 1;

            // Get token text
            const token_text = try detokenizer.detokenize(vocab, token);
            try response_buffer.appendSlice(allocator, token_text);

            // Stream output (only in non-JSON mode)
            if (!json_output) {
                try stdout.print("{s}", .{token_text});
                try stdout.flush();
            }
            detokenizer.clearRetainingCapacity();
        }

        const end_time = std.time.nanoTimestamp();
        last_generation_time_ns = end_time - start_time;
        last_response_tokens = generated_tokens;
        total_response_tokens += generated_tokens;

        // Output based on mode
        if (json_output) {
            // JSON output mode
            const time_sec: f64 = @as(f64, @floatFromInt(last_generation_time_ns)) / 1_000_000_000.0;
            const tokens_per_sec: f64 = if (time_sec > 0) @as(f64, @floatFromInt(generated_tokens)) / time_sec else 0;

            try stdout.print("{{\n", .{});
            try stdout.print("  \"response\": \"", .{});
            // Escape JSON string
            for (response_buffer.items) |c| {
                switch (c) {
                    '"' => try stdout.print("\\\"", .{}),
                    '\\' => try stdout.print("\\\\", .{}),
                    '\n' => try stdout.print("\\n", .{}),
                    '\r' => try stdout.print("\\r", .{}),
                    '\t' => try stdout.print("\\t", .{}),
                    else => try stdout.print("{c}", .{c}),
                }
            }
            try stdout.print("\",\n", .{});
            try stdout.print("  \"prompt_tokens\": {d},\n", .{last_prompt_tokens});
            try stdout.print("  \"response_tokens\": {d},\n", .{generated_tokens});
            try stdout.print("  \"generation_time_sec\": {d:.3},\n", .{time_sec});
            try stdout.print("  \"tokens_per_sec\": {d:.2}\n", .{tokens_per_sec});
            try stdout.print("}}\n", .{});
        } else if (is_interactive) {
            try stdout.print("\n\n", .{});
        } else {
            // Non-interactive text mode: just newline
            try stdout.print("\n", .{});
        }
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
