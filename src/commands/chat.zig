const std = @import("std");
const llama = @import("llama");
const config = @import("../config.zig");
const gguf = @import("../gguf.zig");
const grammar_utils = @import("../grammar.zig");

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

/// Chat template types - supports all major LLM chat formats
const ChatTemplate = enum {
    chatml, // ChatML: <|im_start|>role\ncontent<|im_end|>
    llama3, // Llama 3: <|start_header_id|>role<|end_header_id|>\n\ncontent<|eot_id|>
    llama2, // Llama 2: [INST] <<SYS>>\nsystem<</SYS>>\n\nuser [/INST] assistant </s>
    mistral, // Mistral: [INST] content [/INST] response </s>
    gemma, // Gemma: <start_of_turn>role\ncontent<end_of_turn>
    phi3, // Phi-3: <|system|>\ncontent<|end|>
    qwen, // Qwen: same as ChatML
    vicuna, // Vicuna: USER: content ASSISTANT: response </s>
    alpaca, // Alpaca: ### Instruction:\ncontent\n\n### Response:\n
    deepseek, // DeepSeek: User: content\n\nAssistant: response<｜end▁of▁sentence｜>
    command_r, // Command R: <|START_OF_TURN_TOKEN|><|USER_TOKEN|>content<|END_OF_TURN_TOKEN|>
    zephyr, // Zephyr: <|system|>\ncontent</s>\n<|user|>\ncontent</s>\n<|assistant|>\n
    openchat, // OpenChat: GPT4 Correct User: content<|end_of_turn|>GPT4 Correct Assistant:
    auto,

    pub fn fromString(s: []const u8) ChatTemplate {
        const templates = std.StaticStringMap(ChatTemplate).initComptime(.{
            .{ "chatml", .chatml },
            .{ "llama3", .llama3 },
            .{ "llama2", .llama2 },
            .{ "mistral", .mistral },
            .{ "gemma", .gemma },
            .{ "phi3", .phi3 },
            .{ "phi-3", .phi3 },
            .{ "qwen", .qwen },
            .{ "vicuna", .vicuna },
            .{ "alpaca", .alpaca },
            .{ "deepseek", .deepseek },
            .{ "command-r", .command_r },
            .{ "zephyr", .zephyr },
            .{ "openchat", .openchat },
            .{ "auto", .auto },
        });
        return templates.get(s) orelse .chatml;
    }

    pub fn toString(self: ChatTemplate) []const u8 {
        return switch (self) {
            .chatml => "chatml",
            .llama3 => "llama3",
            .llama2 => "llama2",
            .mistral => "mistral",
            .gemma => "gemma",
            .phi3 => "phi3",
            .qwen => "qwen",
            .vicuna => "vicuna",
            .alpaca => "alpaca",
            .deepseek => "deepseek",
            .command_r => "command-r",
            .zephyr => "zephyr",
            .openchat => "openchat",
            .auto => "auto",
        };
    }

    /// Get a human-readable description of the template
    pub fn description(self: ChatTemplate) []const u8 {
        return switch (self) {
            .chatml => "ChatML format (<|im_start|>/<|im_end|>)",
            .llama3 => "Llama 3 format (<|start_header_id|>/<|eot_id|>)",
            .llama2 => "Llama 2 format ([INST]/<<SYS>>)",
            .mistral => "Mistral/Mixtral format ([INST]/[/INST])",
            .gemma => "Gemma format (<start_of_turn>/<end_of_turn>)",
            .phi3 => "Phi-3 format (<|system|>/<|end|>)",
            .qwen => "Qwen format (ChatML-based)",
            .vicuna => "Vicuna format (USER:/ASSISTANT:)",
            .alpaca => "Alpaca format (### Instruction/### Response)",
            .deepseek => "DeepSeek format (User:/Assistant:)",
            .command_r => "Command R format (<|START_OF_TURN_TOKEN|>)",
            .zephyr => "Zephyr format (<|system|>/</s>)",
            .openchat => "OpenChat format (GPT4 Correct User/Assistant)",
            .auto => "Auto-detect from model metadata",
        };
    }

    /// Detect chat template from GGUF metadata
    /// Reads the `tokenizer.chat_template` key and pattern-matches to known templates
    /// Also checks architecture metadata for additional hints
    pub fn detectFromModel(model: *const llama.Model) ChatTemplate {
        var buffer: [16384]u8 = undefined; // Larger buffer for complex templates

        // Primary: Try to read the chat_template metadata key
        if (model.metaValStr("tokenizer.chat_template", &buffer)) |template_str| {
            return detectFromTemplateString(template_str);
        }

        // Secondary: Check model architecture for hints
        if (model.metaValStr("general.architecture", &buffer)) |arch| {
            const detected = detectFromArchitecture(arch);
            if (detected != .chatml) return detected;
        }

        // Tertiary: try to detect from model name/description
        if (model.metaValStr("general.name", &buffer)) |name| {
            return detectFromModelName(name);
        }

        // Quaternary: check file type metadata
        if (model.metaValStr("general.file_type", &buffer)) |file_type| {
            const detected = detectFromModelName(file_type);
            if (detected != .chatml) return detected;
        }

        // Default to ChatML as it's the most widely compatible
        return .chatml;
    }

    /// Detect template from model architecture
    fn detectFromArchitecture(arch: []const u8) ChatTemplate {
        var lower_buf: [128]u8 = undefined;
        const arch_len = @min(arch.len, lower_buf.len);
        for (arch[0..arch_len], 0..) |c, i| {
            lower_buf[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
        }
        const lower = lower_buf[0..arch_len];

        if (std.mem.indexOf(u8, lower, "llama") != null) {
            // Could be Llama 2 or 3 - default to Llama 3 as newer
            return .llama3;
        }
        if (std.mem.indexOf(u8, lower, "gemma") != null) return .gemma;
        if (std.mem.indexOf(u8, lower, "phi") != null) return .phi3;
        if (std.mem.indexOf(u8, lower, "qwen") != null) return .qwen;
        if (std.mem.indexOf(u8, lower, "mistral") != null) return .mistral;
        if (std.mem.indexOf(u8, lower, "command") != null) return .command_r;

        return .chatml;
    }

    /// Detect template type from the Jinja-style template string
    fn detectFromTemplateString(template: []const u8) ChatTemplate {
        // Llama 3 detection: uses <|start_header_id|> and <|end_header_id|>
        if (std.mem.indexOf(u8, template, "<|start_header_id|>") != null) {
            return .llama3;
        }

        // Llama 2 detection: uses <<SYS>> and <</SYS>>
        if (std.mem.indexOf(u8, template, "<<SYS>>") != null) {
            return .llama2;
        }

        // Command R detection: uses <|START_OF_TURN_TOKEN|>
        if (std.mem.indexOf(u8, template, "<|START_OF_TURN_TOKEN|>") != null) {
            return .command_r;
        }

        // DeepSeek detection: uses special end token
        if (std.mem.indexOf(u8, template, "<\xef\xbd\x9cend") != null or
            std.mem.indexOf(u8, template, "end_of_sentence") != null)
        {
            return .deepseek;
        }

        // Phi-3 detection: uses <|system|>, <|user|>, <|assistant|>, <|end|>
        // Phi-3 specifically uses <|end|> as terminator, not </s>
        if (std.mem.indexOf(u8, template, "<|system|>") != null and
            std.mem.indexOf(u8, template, "<|end|>") != null and
            std.mem.indexOf(u8, template, "</s>") == null)
        {
            return .phi3;
        }

        // Zephyr detection: uses <|system|> and </s> (not <|end|>)
        if (std.mem.indexOf(u8, template, "<|system|>") != null and
            std.mem.indexOf(u8, template, "</s>") != null and
            std.mem.indexOf(u8, template, "<|end|>") == null)
        {
            return .zephyr;
        }

        // If template has <|system|> with both <|end|> and </s>, prefer Phi-3
        if (std.mem.indexOf(u8, template, "<|system|>") != null and
            std.mem.indexOf(u8, template, "<|end|>") != null)
        {
            return .phi3;
        }

        // Gemma detection: uses <start_of_turn> and <end_of_turn>
        if (std.mem.indexOf(u8, template, "<start_of_turn>") != null) {
            return .gemma;
        }

        // Vicuna detection: uses USER: and ASSISTANT:
        if (std.mem.indexOf(u8, template, "USER:") != null and
            std.mem.indexOf(u8, template, "ASSISTANT:") != null)
        {
            return .vicuna;
        }

        // OpenChat detection
        if (std.mem.indexOf(u8, template, "GPT4 Correct") != null) {
            return .openchat;
        }

        // Alpaca detection: uses ### Instruction
        if (std.mem.indexOf(u8, template, "### Instruction") != null) {
            return .alpaca;
        }

        // Mistral detection: uses [INST] and [/INST]
        if (std.mem.indexOf(u8, template, "[INST]") != null and
            std.mem.indexOf(u8, template, "[/INST]") != null)
        {
            return .mistral;
        }

        // ChatML/Qwen detection: uses <|im_start|> and <|im_end|>
        if (std.mem.indexOf(u8, template, "<|im_start|>") != null) {
            // Check if it's specifically Qwen by looking for Qwen-specific patterns
            if (std.mem.indexOf(u8, template, "You are Qwen") != null or
                std.mem.indexOf(u8, template, "qwen") != null)
            {
                return .qwen;
            }
            return .chatml;
        }

        // Default to ChatML
        return .chatml;
    }

    /// Detect template from model name (fallback)
    fn detectFromModelName(name: []const u8) ChatTemplate {
        // Convert to lowercase for case-insensitive matching
        var lower_buf: [512]u8 = undefined;
        const name_len = @min(name.len, lower_buf.len);
        for (name[0..name_len], 0..) |c, i| {
            lower_buf[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
        }
        const lower_name = lower_buf[0..name_len];

        // Check for Llama versions (order matters - check 3 before 2)
        if (std.mem.indexOf(u8, lower_name, "llama-3") != null or
            std.mem.indexOf(u8, lower_name, "llama3") != null or
            std.mem.indexOf(u8, lower_name, "llama_3") != null)
        {
            return .llama3;
        }
        if (std.mem.indexOf(u8, lower_name, "llama-2") != null or
            std.mem.indexOf(u8, lower_name, "llama2") != null)
        {
            return .llama2;
        }
        if (std.mem.indexOf(u8, lower_name, "mistral") != null or
            std.mem.indexOf(u8, lower_name, "mixtral") != null)
        {
            return .mistral;
        }
        if (std.mem.indexOf(u8, lower_name, "gemma") != null) {
            return .gemma;
        }
        if (std.mem.indexOf(u8, lower_name, "phi-3") != null or
            std.mem.indexOf(u8, lower_name, "phi3") != null or
            std.mem.indexOf(u8, lower_name, "phi_3") != null)
        {
            return .phi3;
        }
        if (std.mem.indexOf(u8, lower_name, "qwen") != null) {
            return .qwen;
        }
        if (std.mem.indexOf(u8, lower_name, "vicuna") != null) {
            return .vicuna;
        }
        if (std.mem.indexOf(u8, lower_name, "alpaca") != null) {
            return .alpaca;
        }
        if (std.mem.indexOf(u8, lower_name, "deepseek") != null) {
            return .deepseek;
        }
        if (std.mem.indexOf(u8, lower_name, "command-r") != null or
            std.mem.indexOf(u8, lower_name, "command_r") != null or
            std.mem.indexOf(u8, lower_name, "commandr") != null)
        {
            return .command_r;
        }
        if (std.mem.indexOf(u8, lower_name, "zephyr") != null) {
            return .zephyr;
        }
        if (std.mem.indexOf(u8, lower_name, "openchat") != null) {
            return .openchat;
        }
        if (std.mem.indexOf(u8, lower_name, "tinyllama") != null) {
            return .chatml; // TinyLlama uses ChatML
        }

        return .chatml;
    }
};

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

    /// Format conversation using Llama 2 template
    /// <s>[INST] <<SYS>>\nsystem\n<</SYS>>\n\nuser [/INST] assistant </s><s>[INST] user [/INST]
    pub fn formatLlama2(self: *ChatSession, allocator: std.mem.Allocator) ![]const u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);

        try result.appendSlice(allocator, "<s>");

        var is_first_user = true;
        for (self.messages.items) |msg| {
            switch (msg.role) {
                .user => {
                    try result.appendSlice(allocator, "[INST] ");
                    if (is_first_user and self.system_prompt.len > 0) {
                        try result.appendSlice(allocator, "<<SYS>>\n");
                        try result.appendSlice(allocator, self.system_prompt);
                        try result.appendSlice(allocator, "\n<</SYS>>\n\n");
                    }
                    try result.appendSlice(allocator, msg.content);
                    try result.appendSlice(allocator, " [/INST]");
                    is_first_user = false;
                },
                .assistant => {
                    try result.appendSlice(allocator, " ");
                    try result.appendSlice(allocator, msg.content);
                    try result.appendSlice(allocator, " </s><s>");
                },
                .system => {
                    // System messages handled with first user message
                },
            }
        }

        return result.toOwnedSlice(allocator);
    }

    /// Format conversation using Vicuna template
    /// USER: content ASSISTANT: response</s>USER: content ASSISTANT:
    pub fn formatVicuna(self: *ChatSession, allocator: std.mem.Allocator) ![]const u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);

        // System prompt first
        if (self.system_prompt.len > 0) {
            try result.appendSlice(allocator, self.system_prompt);
            try result.appendSlice(allocator, "\n\n");
        }

        for (self.messages.items) |msg| {
            switch (msg.role) {
                .user => {
                    try result.appendSlice(allocator, "USER: ");
                    try result.appendSlice(allocator, msg.content);
                    try result.appendSlice(allocator, "\n");
                },
                .assistant => {
                    try result.appendSlice(allocator, "ASSISTANT: ");
                    try result.appendSlice(allocator, msg.content);
                    try result.appendSlice(allocator, "</s>\n");
                },
                .system => {
                    try result.appendSlice(allocator, msg.content);
                    try result.appendSlice(allocator, "\n");
                },
            }
        }

        // Prompt for assistant response
        try result.appendSlice(allocator, "ASSISTANT:");

        return result.toOwnedSlice(allocator);
    }

    /// Format conversation using Alpaca template
    /// ### Instruction:\ncontent\n\n### Response:\nresponse\n\n
    pub fn formatAlpaca(self: *ChatSession, allocator: std.mem.Allocator) ![]const u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);

        // System prompt as instruction prefix
        if (self.system_prompt.len > 0) {
            try result.appendSlice(allocator, "Below is an instruction that describes a task. ");
            try result.appendSlice(allocator, "Write a response that appropriately completes the request.\n\n");
            try result.appendSlice(allocator, "### System:\n");
            try result.appendSlice(allocator, self.system_prompt);
            try result.appendSlice(allocator, "\n\n");
        }

        for (self.messages.items) |msg| {
            switch (msg.role) {
                .user => {
                    try result.appendSlice(allocator, "### Instruction:\n");
                    try result.appendSlice(allocator, msg.content);
                    try result.appendSlice(allocator, "\n\n");
                },
                .assistant => {
                    try result.appendSlice(allocator, "### Response:\n");
                    try result.appendSlice(allocator, msg.content);
                    try result.appendSlice(allocator, "\n\n");
                },
                .system => {
                    try result.appendSlice(allocator, "### System:\n");
                    try result.appendSlice(allocator, msg.content);
                    try result.appendSlice(allocator, "\n\n");
                },
            }
        }

        // Prompt for response
        try result.appendSlice(allocator, "### Response:\n");

        return result.toOwnedSlice(allocator);
    }

    /// Format conversation using DeepSeek template
    /// User: content\n\nAssistant: response<｜end▁of▁sentence｜>
    pub fn formatDeepSeek(self: *ChatSession, allocator: std.mem.Allocator) ![]const u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);

        // System prompt
        if (self.system_prompt.len > 0) {
            try result.appendSlice(allocator, self.system_prompt);
            try result.appendSlice(allocator, "\n\n");
        }

        for (self.messages.items) |msg| {
            switch (msg.role) {
                .user => {
                    try result.appendSlice(allocator, "User: ");
                    try result.appendSlice(allocator, msg.content);
                    try result.appendSlice(allocator, "\n\n");
                },
                .assistant => {
                    try result.appendSlice(allocator, "Assistant: ");
                    try result.appendSlice(allocator, msg.content);
                    // DeepSeek end token (UTF-8 encoded)
                    try result.appendSlice(allocator, "<\xef\xbd\x9cend\xe2\x96\x81of\xe2\x96\x81sentence\xef\xbd\x9c>");
                },
                .system => {
                    try result.appendSlice(allocator, msg.content);
                    try result.appendSlice(allocator, "\n\n");
                },
            }
        }

        // Prompt for assistant
        try result.appendSlice(allocator, "Assistant:");

        return result.toOwnedSlice(allocator);
    }

    /// Format conversation using Command R template
    /// <|START_OF_TURN_TOKEN|><|SYSTEM_TOKEN|>content<|END_OF_TURN_TOKEN|>
    pub fn formatCommandR(self: *ChatSession, allocator: std.mem.Allocator) ![]const u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);

        try result.appendSlice(allocator, "<BOS_TOKEN>");

        // System prompt
        if (self.system_prompt.len > 0) {
            try result.appendSlice(allocator, "<|START_OF_TURN_TOKEN|><|SYSTEM_TOKEN|>");
            try result.appendSlice(allocator, self.system_prompt);
            try result.appendSlice(allocator, "<|END_OF_TURN_TOKEN|>");
        }

        for (self.messages.items) |msg| {
            try result.appendSlice(allocator, "<|START_OF_TURN_TOKEN|>");
            try result.appendSlice(allocator, switch (msg.role) {
                .user => "<|USER_TOKEN|>",
                .assistant => "<|CHATBOT_TOKEN|>",
                .system => "<|SYSTEM_TOKEN|>",
            });
            try result.appendSlice(allocator, msg.content);
            try result.appendSlice(allocator, "<|END_OF_TURN_TOKEN|>");
        }

        // Prompt for assistant
        try result.appendSlice(allocator, "<|START_OF_TURN_TOKEN|><|CHATBOT_TOKEN|>");

        return result.toOwnedSlice(allocator);
    }

    /// Format conversation using Zephyr template
    /// <|system|>\ncontent</s>\n<|user|>\ncontent</s>\n<|assistant|>\n
    pub fn formatZephyr(self: *ChatSession, allocator: std.mem.Allocator) ![]const u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);

        // System prompt
        if (self.system_prompt.len > 0) {
            try result.appendSlice(allocator, "<|system|>\n");
            try result.appendSlice(allocator, self.system_prompt);
            try result.appendSlice(allocator, "</s>\n");
        }

        for (self.messages.items) |msg| {
            try result.appendSlice(allocator, switch (msg.role) {
                .user => "<|user|>\n",
                .assistant => "<|assistant|>\n",
                .system => "<|system|>\n",
            });
            try result.appendSlice(allocator, msg.content);
            try result.appendSlice(allocator, "</s>\n");
        }

        // Prompt for assistant
        try result.appendSlice(allocator, "<|assistant|>\n");

        return result.toOwnedSlice(allocator);
    }

    /// Format conversation using OpenChat template
    /// GPT4 Correct User: content<|end_of_turn|>GPT4 Correct Assistant: response<|end_of_turn|>
    pub fn formatOpenChat(self: *ChatSession, allocator: std.mem.Allocator) ![]const u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);

        // System prompt (add as first user message context)
        if (self.system_prompt.len > 0) {
            try result.appendSlice(allocator, "GPT4 Correct System: ");
            try result.appendSlice(allocator, self.system_prompt);
            try result.appendSlice(allocator, "<|end_of_turn|>");
        }

        for (self.messages.items) |msg| {
            switch (msg.role) {
                .user => {
                    try result.appendSlice(allocator, "GPT4 Correct User: ");
                    try result.appendSlice(allocator, msg.content);
                    try result.appendSlice(allocator, "<|end_of_turn|>");
                },
                .assistant => {
                    try result.appendSlice(allocator, "GPT4 Correct Assistant: ");
                    try result.appendSlice(allocator, msg.content);
                    try result.appendSlice(allocator, "<|end_of_turn|>");
                },
                .system => {
                    try result.appendSlice(allocator, "GPT4 Correct System: ");
                    try result.appendSlice(allocator, msg.content);
                    try result.appendSlice(allocator, "<|end_of_turn|>");
                },
            }
        }

        // Prompt for assistant
        try result.appendSlice(allocator, "GPT4 Correct Assistant:");

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
    var template: ChatTemplate = .auto; // auto-detect from model metadata
    var context_size: ?u32 = null; // Override context size (null = use model default)
    var seed: u32 = 0; // 0 = random seed
    var quiet_mode: bool = false; // Suppress model loading logs
    var temperature: f32 = 0.7; // Sampling temperature
    var top_p: f32 = 0.9; // Top-p (nucleus) sampling
    var top_k: i32 = 40; // Top-k sampling
    var repeat_penalty: f32 = 1.1; // Repetition penalty
    var single_prompt: ?[]const u8 = null; // Single-turn mode prompt
    var json_output: bool = false; // JSON output mode
    var grammar_string: ?[]const u8 = null; // Grammar string (GBNF format)
    var grammar_file: ?[]const u8 = null; // Path to grammar file

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--model") or std.mem.eql(u8, arg, "-m")) {
            if (i + 1 < args.len) {
                const path_z = try allocator.allocSentinel(u8, args[i + 1].len, 0);
                @memcpy(path_z, args[i + 1]);
                model_path = path_z;
                i += 1;
            } else {
                try stderr.print("Error: {s} requires a value\n", .{arg});
                return error.InvalidArguments;
            }
        } else if (std.mem.eql(u8, arg, "--gpu-layers") or std.mem.eql(u8, arg, "-ngl")) {
            if (i + 1 < args.len) {
                gpu_layers = std.fmt.parseInt(i32, args[i + 1], 10) catch 0;
                i += 1;
            } else {
                try stderr.print("Error: {s} requires a value\n", .{arg});
                return error.InvalidArguments;
            }
        } else if (std.mem.eql(u8, arg, "--max-tokens") or std.mem.eql(u8, arg, "-n")) {
            if (i + 1 < args.len) {
                max_tokens = std.fmt.parseInt(usize, args[i + 1], 10) catch 2048;
                i += 1;
            } else {
                try stderr.print("Error: {s} requires a value\n", .{arg});
                return error.InvalidArguments;
            }
        } else if (std.mem.eql(u8, arg, "--system") or std.mem.eql(u8, arg, "-s")) {
            if (i + 1 < args.len) {
                system_prompt = args[i + 1];
                i += 1;
            } else {
                try stderr.print("Error: {s} requires a value\n", .{arg});
                return error.InvalidArguments;
            }
        } else if (std.mem.eql(u8, arg, "--template") or std.mem.eql(u8, arg, "-t")) {
            if (i + 1 < args.len) {
                template = ChatTemplate.fromString(args[i + 1]);
                i += 1;
            } else {
                try stderr.print("Error: {s} requires a value\n", .{arg});
                return error.InvalidArguments;
            }
        } else if (std.mem.eql(u8, arg, "--context-size") or std.mem.eql(u8, arg, "-c")) {
            if (i + 1 < args.len) {
                context_size = std.fmt.parseInt(u32, args[i + 1], 10) catch null;
                i += 1;
            } else {
                try stderr.print("Error: {s} requires a value\n", .{arg});
                return error.InvalidArguments;
            }
        } else if (std.mem.eql(u8, arg, "--seed")) {
            if (i + 1 < args.len) {
                seed = std.fmt.parseInt(u32, args[i + 1], 10) catch 0;
                i += 1;
            } else {
                try stderr.print("Error: {s} requires a value\n", .{arg});
                return error.InvalidArguments;
            }
        } else if (std.mem.eql(u8, arg, "--temp") or std.mem.eql(u8, arg, "--temperature")) {
            if (i + 1 < args.len) {
                temperature = std.fmt.parseFloat(f32, args[i + 1]) catch 0.7;
                i += 1;
            } else {
                try stderr.print("Error: {s} requires a value\n", .{arg});
                return error.InvalidArguments;
            }
        } else if (std.mem.eql(u8, arg, "--top-p")) {
            if (i + 1 < args.len) {
                top_p = std.fmt.parseFloat(f32, args[i + 1]) catch 0.9;
                i += 1;
            } else {
                try stderr.print("Error: {s} requires a value\n", .{arg});
                return error.InvalidArguments;
            }
        } else if (std.mem.eql(u8, arg, "--top-k")) {
            if (i + 1 < args.len) {
                top_k = std.fmt.parseInt(i32, args[i + 1], 10) catch 40;
                i += 1;
            } else {
                try stderr.print("Error: {s} requires a value\n", .{arg});
                return error.InvalidArguments;
            }
        } else if (std.mem.eql(u8, arg, "--repeat-penalty")) {
            if (i + 1 < args.len) {
                repeat_penalty = std.fmt.parseFloat(f32, args[i + 1]) catch 1.1;
                i += 1;
            } else {
                try stderr.print("Error: {s} requires a value\n", .{arg});
                return error.InvalidArguments;
            }
        } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            quiet_mode = true;
        } else if (std.mem.eql(u8, arg, "--prompt") or std.mem.eql(u8, arg, "-p")) {
            if (i + 1 < args.len) {
                single_prompt = args[i + 1];
                i += 1;
            } else {
                try stderr.print("Error: {s} requires a value\n", .{arg});
                return error.InvalidArguments;
            }
        } else if (std.mem.eql(u8, arg, "--json")) {
            json_output = true;
        } else if (std.mem.eql(u8, arg, "--grammar") or std.mem.eql(u8, arg, "-g")) {
            if (i + 1 < args.len) {
                grammar_string = args[i + 1];
                i += 1;
            } else {
                try stderr.print("Error: {s} requires a value\n", .{arg});
                return error.InvalidArguments;
            }
        } else if (std.mem.eql(u8, arg, "--grammar-file") or std.mem.eql(u8, arg, "-gf")) {
            if (i + 1 < args.len) {
                grammar_file = args[i + 1];
                i += 1;
            } else {
                try stderr.print("Error: {s} requires a value\n", .{arg});
                return error.InvalidArguments;
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
        try stderr.print("  -c, --context-size <n>   Context size (default: model's training size)\n", .{});
        try stderr.print("  -n, --max-tokens <n>     Max tokens per response (default: 2048)\n", .{});
        try stderr.print("  -s, --system <prompt>    System prompt (default: helpful assistant)\n", .{});
        try stderr.print("  -t, --template <name>    Chat template: auto, chatml, llama3, llama2, mistral, gemma,\n", .{});
        try stderr.print("                           phi3, qwen, vicuna, alpaca, deepseek, command-r, zephyr, openchat\n", .{});
        try stderr.print("  -ngl, --gpu-layers <n>   GPU layers to offload (default: 0)\n", .{});
        try stderr.print("  -q, --quiet              Suppress model loading logs\n", .{});
        try stderr.print("  -p, --prompt <text>      Single-turn mode: generate response and exit\n", .{});
        try stderr.print("  --json                   Output response as JSON (for scripting)\n", .{});
        try stderr.print("\nGrammar options:\n", .{});
        try stderr.print("  -g, --grammar <gbnf>     GBNF grammar string for constrained output\n", .{});
        try stderr.print("  -gf, --grammar-file <f>  Path to GBNF grammar file\n", .{});
        try stderr.print("                           Use 'json' as shorthand for JSON object grammar\n", .{});
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

    // Validate GGUF file before loading
    const validation = gguf.validateFile(model_path.?);
    if (!validation.valid) {
        try stderr.print("Error: Invalid model file: {s}\n", .{validation.error_message orelse "Unknown error"});
        if (validation.file_size > 0) {
            var size_buf: [32]u8 = undefined;
            try stderr.print("  File size: {s}\n", .{gguf.formatFileSize(validation.file_size, &size_buf)});
        }
        if (validation.error_code) |code| {
            try stderr.print("  Error code: {s}\n", .{@tagName(code)});
        }
        const suggestion = validation.getSuggestion();
        if (suggestion.len > 0) {
            try stderr.print("\nSuggestion: {s}\n", .{suggestion});
        }
        try stderr.print("\nPlease ensure you have a valid GGUF model file.\n", .{});
        try stderr.print("You can download models using: igllama pull <repo_id>\n", .{});
        return error.InvalidGgufFile;
    }

    if (!quiet_mode) {
        try stdout.print("Loading model: {s}\n", .{model_path.?});
        var size_buf: [32]u8 = undefined;
        try stdout.print("  GGUF v{d} | {s} | {d} tensors\n", .{
            validation.version orelse 0,
            gguf.formatFileSize(validation.file_size, &size_buf),
            validation.tensor_count orelse 0,
        });

        // Show additional model info if available
        const info = validation.model_info;
        if (info.architecture != .unknown) {
            try stdout.print("  Architecture: {s}\n", .{info.architecture.toString()});
        }
        if (info.quantization != .Unknown) {
            try stdout.print("  Quantization: {s}\n", .{info.quantization.description()});
        }
        if (info.context_length) |ctx| {
            try stdout.print("  Training context: {d} tokens\n", .{ctx});
        }
        if (info.layer_count) |layers| {
            if (info.embedding_length) |embd| {
                try stdout.print("  Layers: {d}, Embedding: {d}\n", .{ layers, embd });
            }
        }

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

    // Auto-detect chat template from model metadata if not explicitly set
    const effective_template: ChatTemplate = if (template == .auto) blk: {
        const detected = ChatTemplate.detectFromModel(model);
        if (!quiet_mode) {
            try stdout.print("Auto-detected template: {s}\n", .{detected.toString()});
            try stdout.flush();
        }
        break :blk detected;
    } else template;

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
        // Load grammar from file or use built-in
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
        if (!quiet_mode) {
            if (std.mem.eql(u8, gf, "json") or std.mem.eql(u8, gf, "json-array")) {
                try stdout.print("Using built-in {s} grammar\n", .{gf});
            } else {
                try stdout.print("Loaded grammar from: {s}\n", .{gf});
            }
        }
    }

    // Determine run mode: interactive, single-prompt, or piped
    const is_tty = isStdinTty();
    const is_interactive = is_tty and single_prompt == null;

    if (is_interactive and !quiet_mode) {
        try stdout.print("\n{s} v{s} - Interactive Chat\n", .{ config.app_name, config.version });
        try stdout.print("Model: {s}\n", .{model_path.?});
        try stdout.print("Template: {s} | Context: {d} tokens\n", .{ effective_template.toString(), effective_ctx_size });
        if (temperature == 0) {
            try stdout.print("Sampling: greedy", .{});
        } else {
            try stdout.print("Sampling: temp={d:.2}, top_p={d:.2}, top_k={d}", .{ temperature, top_p, top_k });
        }
        if (effective_grammar != null) {
            try stdout.print(" | Grammar: enabled", .{});
        }
        try stdout.print("\n", .{});
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
        const formatted_prompt = switch (effective_template) {
            .llama3 => try session.formatLlama3(allocator),
            .llama2 => try session.formatLlama2(allocator),
            .mistral => try session.formatMistral(allocator),
            .gemma => try session.formatGemma(allocator),
            .phi3 => try session.formatPhi3(allocator),
            .qwen => try session.formatQwen(allocator),
            .vicuna => try session.formatVicuna(allocator),
            .alpaca => try session.formatAlpaca(allocator),
            .deepseek => try session.formatDeepSeek(allocator),
            .command_r => try session.formatCommandR(allocator),
            .zephyr => try session.formatZephyr(allocator),
            .openchat => try session.formatOpenChat(allocator),
            .chatml, .auto => try session.formatChatML(allocator),
        };
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

        // Add grammar sampler first if specified (constrains generation to valid grammar)
        if (effective_grammar) |grammar| {
            sampler.add(llama.Sampler.initGrammar(vocab, grammar, "root"));
        }

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
            batch.decode(ctx) catch |err| {
                switch (err) {
                    error.NoKvSlotWarning => {
                        try stderr.print("\nWarning: KV cache full. Try clearing conversation with /clear\n", .{});
                        break;
                    },
                    error.DecodeError => {
                        try stderr.print("\nError during generation. The model may be incompatible.\n", .{});
                        break;
                    },
                    else => break,
                }
            };
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
