const std = @import("std");
const llama = @import("llama");
const config = @import("../config.zig");
const gguf = @import("../gguf.zig");

/// API Server State - holds the loaded model and context
const ServerState = struct {
    allocator: std.mem.Allocator,
    model: *llama.Model,
    vocab: *const llama.Vocab,
    model_name: []const u8,
    context_size: u32,
    temperature: f32,
    top_p: f32,
    top_k: i32,
    max_tokens: usize,
    n_threads: i32,
    n_threads_batch: i32,
    no_think: bool,

    pub fn deinit(self: *ServerState) void {
        self.model.deinit();
        self.allocator.free(self.model_name);
    }
};

/// Chat message for OpenAI API format
const ChatMessage = struct {
    role: []const u8,
    content: []const u8,
};

/// Parse JSON string value starting at position, returns value and end position
fn parseJsonString(data: []const u8, start: usize) ?struct { value: []const u8, end: usize } {
    if (start >= data.len or data[start] != '"') return null;

    var pos = start + 1;
    const str_start = pos;

    while (pos < data.len) {
        if (data[pos] == '\\' and pos + 1 < data.len) {
            pos += 2; // Skip escaped char
        } else if (data[pos] == '"') {
            return .{ .value = data[str_start..pos], .end = pos + 1 };
        } else {
            pos += 1;
        }
    }
    return null;
}

/// Simple JSON parser for chat completions request
fn parseChatRequest(allocator: std.mem.Allocator, body: []const u8) !struct {
    messages: std.ArrayList(ChatMessage),
    stream: bool,
    max_tokens: ?usize,
    temperature: ?f32,
    json_mode: bool,
} {
    var messages: std.ArrayList(ChatMessage) = .empty;
    var stream = false;
    var max_tokens: ?usize = null;
    var temperature: ?f32 = null;
    var json_mode = false;

    // Find "stream": true/false
    if (std.mem.indexOf(u8, body, "\"stream\"")) |stream_pos| {
        var pos = stream_pos + 8;
        while (pos < body.len and (body[pos] == ':' or body[pos] == ' ')) : (pos += 1) {}
        if (pos + 4 <= body.len and std.mem.eql(u8, body[pos .. pos + 4], "true")) {
            stream = true;
        }
    }

    // Find "max_tokens": number
    if (std.mem.indexOf(u8, body, "\"max_tokens\"")) |mt_pos| {
        var pos = mt_pos + 12;
        while (pos < body.len and (body[pos] == ':' or body[pos] == ' ')) : (pos += 1) {}
        var num_end = pos;
        while (num_end < body.len and body[num_end] >= '0' and body[num_end] <= '9') : (num_end += 1) {}
        if (num_end > pos) {
            max_tokens = std.fmt.parseInt(usize, body[pos..num_end], 10) catch null;
        }
    }

    // Find response_format: {"type":"json_object"} — enables grammar-constrained JSON output
    if (std.mem.indexOf(u8, body, "\"json_object\"")) |_| {
        json_mode = true;
    }

    // Find "temperature": number
    if (std.mem.indexOf(u8, body, "\"temperature\"")) |temp_pos| {
        var pos = temp_pos + 13;
        while (pos < body.len and (body[pos] == ':' or body[pos] == ' ')) : (pos += 1) {}
        var num_end = pos;
        while (num_end < body.len and (body[num_end] >= '0' and body[num_end] <= '9' or body[num_end] == '.')) : (num_end += 1) {}
        if (num_end > pos) {
            temperature = std.fmt.parseFloat(f32, body[pos..num_end]) catch null;
        }
    }

    // Find "messages": [...]
    if (std.mem.indexOf(u8, body, "\"messages\"")) |msg_start| {
        var pos = msg_start + 10;
        // Find opening bracket
        while (pos < body.len and body[pos] != '[') : (pos += 1) {}
        if (pos >= body.len) return .{ .messages = messages, .stream = stream, .max_tokens = max_tokens, .temperature = temperature, .json_mode = json_mode };
        pos += 1;

        // Parse each message object
        while (pos < body.len) {
            // Skip whitespace and commas
            while (pos < body.len and (body[pos] == ' ' or body[pos] == '\n' or body[pos] == '\r' or body[pos] == '\t' or body[pos] == ',')) : (pos += 1) {}

            if (pos >= body.len or body[pos] == ']') break;
            if (body[pos] != '{') {
                pos += 1;
                continue;
            }
            pos += 1;

            var role: []const u8 = "user";
            var content: []const u8 = "";

            // Parse message object
            while (pos < body.len and body[pos] != '}') {
                // Skip whitespace
                while (pos < body.len and (body[pos] == ' ' or body[pos] == '\n' or body[pos] == '\r' or body[pos] == '\t' or body[pos] == ',' or body[pos] == ':')) : (pos += 1) {}

                if (pos >= body.len) break;

                // Check for "role"
                if (pos + 6 <= body.len and std.mem.eql(u8, body[pos .. pos + 6], "\"role\"")) {
                    pos += 6;
                    while (pos < body.len and (body[pos] == ':' or body[pos] == ' ')) : (pos += 1) {}
                    if (parseJsonString(body, pos)) |result| {
                        role = result.value;
                        pos = result.end;
                    }
                }
                // Check for "content"
                else if (pos + 9 <= body.len and std.mem.eql(u8, body[pos .. pos + 9], "\"content\"")) {
                    pos += 9;
                    while (pos < body.len and (body[pos] == ':' or body[pos] == ' ')) : (pos += 1) {}
                    if (parseJsonString(body, pos)) |result| {
                        content = result.value;
                        pos = result.end;
                    }
                } else {
                    pos += 1;
                }
            }

            if (pos < body.len and body[pos] == '}') {
                pos += 1;
            }

            try messages.append(allocator, .{ .role = role, .content = content });
        }
    }

    return .{ .messages = messages, .stream = stream, .max_tokens = max_tokens, .temperature = temperature, .json_mode = json_mode };
}

/// Format messages using ChatML template.
/// When no_think is true, prefills an empty <think></think> block on the
/// assistant turn to suppress Qwen3-style chain-of-thought reasoning output.
fn formatChatML(allocator: std.mem.Allocator, messages: []const ChatMessage, no_think: bool) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    for (messages) |msg| {
        try result.appendSlice(allocator, "<|im_start|>");
        try result.appendSlice(allocator, msg.role);
        try result.appendSlice(allocator, "\n");
        try result.appendSlice(allocator, msg.content);
        try result.appendSlice(allocator, "<|im_end|>\n");
    }

    if (no_think) {
        try result.appendSlice(allocator, "<|im_start|>assistant\n<think>\n\n</think>\n");
    } else {
        try result.appendSlice(allocator, "<|im_start|>assistant\n");
    }

    return result.toOwnedSlice(allocator);
}

/// Parse embeddings request - supports both single string and array of strings
fn parseEmbeddingsRequest(allocator: std.mem.Allocator, body: []const u8) !struct {
    inputs: std.ArrayList([]const u8),
} {
    var inputs: std.ArrayList([]const u8) = .empty;
    errdefer inputs.deinit(allocator);

    // Find "input" field
    if (std.mem.indexOf(u8, body, "\"input\"")) |input_start| {
        var pos = input_start + 7;
        // Skip to colon
        while (pos < body.len and body[pos] != ':') : (pos += 1) {}
        pos += 1;
        // Skip whitespace
        while (pos < body.len and (body[pos] == ' ' or body[pos] == '\n' or body[pos] == '\r' or body[pos] == '\t')) : (pos += 1) {}

        if (pos >= body.len) return .{ .inputs = inputs };

        if (body[pos] == '"') {
            // Single string input
            if (parseJsonString(body, pos)) |result| {
                try inputs.append(allocator, result.value);
            }
        } else if (body[pos] == '[') {
            // Array of strings
            pos += 1;
            while (pos < body.len) {
                // Skip whitespace and commas
                while (pos < body.len and (body[pos] == ' ' or body[pos] == '\n' or body[pos] == '\r' or body[pos] == '\t' or body[pos] == ',')) : (pos += 1) {}

                if (pos >= body.len or body[pos] == ']') break;

                if (body[pos] == '"') {
                    if (parseJsonString(body, pos)) |result| {
                        try inputs.append(allocator, result.value);
                        pos = result.end;
                    } else {
                        pos += 1;
                    }
                } else {
                    pos += 1;
                }
            }
        }
    }

    return .{ .inputs = inputs };
}

/// Generate embeddings for a list of input texts
fn handleEmbeddings(
    state: *ServerState,
    inputs: []const []const u8,
) !struct {
    embeddings: std.ArrayList(std.ArrayList(f32)),
    total_tokens: usize,
} {
    const allocator = state.allocator;

    var embeddings: std.ArrayList(std.ArrayList(f32)) = .empty;
    errdefer {
        for (embeddings.items) |*e| e.deinit(allocator);
        embeddings.deinit(allocator);
    }

    var total_tokens: usize = 0;

    // Create context with embeddings enabled
    var cparams = llama.Context.defaultParams();
    cparams.n_ctx = state.context_size;
    cparams.n_batch = state.context_size;
    cparams.embeddings = true; // Enable embeddings extraction
    cparams.n_threads = state.n_threads;
    cparams.n_threads_batch = state.n_threads_batch;
    cparams.no_perf = true;

    const ctx = llama.Context.initWithModel(state.model, cparams) catch {
        return error.ContextCreationFailed;
    };
    defer ctx.deinit();

    // Get embedding dimension
    const n_embd = state.model.nEmbd();

    // Process each input
    for (inputs) |input| {
        // Tokenize
        var tokenizer = llama.Tokenizer.init(allocator);
        defer tokenizer.deinit();
        try tokenizer.tokenize(state.vocab, input, true, true);

        const tokens = tokenizer.getTokens();
        total_tokens += tokens.len;

        // Clear KV cache for this input (use new Memory API)
        if (ctx.getMemory()) |memory| {
            memory.clear(true);
        }

        // Create batch and decode
        var batch = llama.Batch.initOne(tokens);
        batch.decode(ctx) catch {
            return error.DecodeFailed;
        };

        // Extract embeddings - use the last token position
        // llama_get_embeddings returns the pooled embedding for the sequence
        const embd_ptr = ctx.llama_get_embeddings();

        // Copy embeddings to result
        var embd_vec: std.ArrayList(f32) = .empty;
        try embd_vec.appendSlice(allocator, embd_ptr[0..@intCast(n_embd)]);
        try embeddings.append(allocator, embd_vec);
    }

    return .{
        .embeddings = embeddings,
        .total_tokens = total_tokens,
    };
}

/// Generate completion and write SSE events to connection
fn handleStreamingCompletion(
    state: *ServerState,
    conn: *std.net.Server.Connection,
    messages: []const ChatMessage,
    max_tokens: usize,
    temperature: f32,
    request_id: []const u8,
    json_mode: bool,
) !void {
    const allocator = state.allocator;

    // Format prompt
    const prompt = try formatChatML(allocator, messages, state.no_think);
    defer allocator.free(prompt);

    // Create context for this request
    var cparams = llama.Context.defaultParams();
    cparams.n_ctx = state.context_size;
    cparams.n_batch = state.context_size;
    cparams.n_threads = state.n_threads;
    cparams.n_threads_batch = state.n_threads_batch;
    cparams.no_perf = true;

    const ctx = llama.Context.initWithModel(state.model, cparams) catch {
        try sendSSEError(conn, "Failed to create context");
        return;
    };
    defer ctx.deinit();

    // Setup sampler
    var sampler = llama.Sampler.initChain(.{ .no_perf = true });
    defer sampler.deinit();

    if (temperature == 0) {
        sampler.add(llama.Sampler.initGreedy());
    } else {
        sampler.add(llama.Sampler.initTopK(state.top_k));
        sampler.add(llama.Sampler.initTopP(state.top_p, 1));
        sampler.add(llama.Sampler.initTemp(temperature));
        sampler.add(llama.Sampler.initDist(0));
    }

    // Grammar-constrained sampling: when json_mode is requested, add a JSON
    // grammar sampler that sets -inf logits for tokens violating JSON syntax
    // at the current parse state. This eliminates malformed/non-JSON output.
    if (json_mode) {
        const grammar_str = @import("../grammar.zig").JSON_GRAMMAR;
        sampler.add(llama.Sampler.initGrammar(state.vocab, grammar_str, "root"));
    }

    // Tokenize
    var tokenizer = llama.Tokenizer.init(allocator);
    defer tokenizer.deinit();
    try tokenizer.tokenize(state.vocab, prompt, false, true);

    var detokenizer = llama.Detokenizer.init(allocator);
    defer detokenizer.deinit();

    const created = std.time.timestamp();

    // Send initial role chunk (required by OpenAI-compatible clients)
    sendSSERoleChunk(conn, request_id, state.model_name, created);

    // Generate tokens
    var batch = llama.Batch.initOne(tokenizer.getTokens());
    var batch_token: [1]llama.Token = undefined;

    // When --no-think is active, buffer initial tokens to strip residual </think>
    var think_buf: std.ArrayList(u8) = .empty;
    defer think_buf.deinit(allocator);
    var think_stripped = !state.no_think; // true = already done / not needed

    for (0..max_tokens) |_| {
        batch.decode(ctx) catch break;
        const token = sampler.sample(ctx, -1);
        if (state.vocab.isEog(token)) break;

        batch_token[0] = token;
        batch = llama.Batch.initOne(batch_token[0..]);

        // Detokenize and send SSE event
        const token_text = detokenizer.detokenize(state.vocab, token) catch continue;
        detokenizer.clearRetainingCapacity();

        if (!think_stripped) {
            // Buffer initial tokens until we can determine if </think> is present
            think_buf.appendSlice(allocator, token_text) catch continue;
            const buf = think_buf.items;
            // Skip leading whitespace to find </think>
            var start: usize = 0;
            while (start < buf.len and (buf[start] == ' ' or buf[start] == '\n' or buf[start] == '\r' or buf[start] == '\t')) : (start += 1) {}
            const think_end = "</think>";
            if (start + think_end.len <= buf.len) {
                if (std.mem.eql(u8, buf[start .. start + think_end.len], think_end)) {
                    // Found </think> — skip it and flush remainder
                    var trim_start = start + think_end.len;
                    while (trim_start < buf.len and (buf[trim_start] == ' ' or buf[trim_start] == '\n' or buf[trim_start] == '\r' or buf[trim_start] == '\t')) : (trim_start += 1) {}
                    if (trim_start < buf.len) {
                        sendSSEToken(conn, buf[trim_start..], request_id, state.model_name, created) catch {};
                    }
                } else {
                    // Not </think> — flush entire buffer
                    sendSSEToken(conn, buf, request_id, state.model_name, created) catch {};
                }
                think_stripped = true;
            } else if (buf.len > 20) {
                // Buffer too large without matching — flush as-is
                sendSSEToken(conn, buf, request_id, state.model_name, created) catch {};
                think_stripped = true;
            }
            // else: keep buffering
        } else {
            try sendSSEToken(conn, token_text, request_id, state.model_name, created);
        }
    }

    // Flush any remaining buffered tokens
    if (!think_stripped and think_buf.items.len > 0) {
        sendSSEToken(conn, think_buf.items, request_id, state.model_name, created) catch {};
    }

    // Send final stop chunk then [DONE]
    sendSSEStopChunk(conn, request_id, state.model_name, created);
    try sendSSEDone(conn);
}

/// Escape a string for embedding in a JSON value (in-place into dest buffer).
fn jsonEscape(src: []const u8, dest: []u8) usize {
    var out: usize = 0;
    for (src) |c| {
        if (out + 2 >= dest.len) break;
        switch (c) {
            '"' => { dest[out] = '\\'; dest[out + 1] = '"';  out += 2; },
            '\\' => { dest[out] = '\\'; dest[out + 1] = '\\'; out += 2; },
            '\n' => { dest[out] = '\\'; dest[out + 1] = 'n';  out += 2; },
            '\r' => { dest[out] = '\\'; dest[out + 1] = 'r';  out += 2; },
            '\t' => { dest[out] = '\\'; dest[out + 1] = 't';  out += 2; },
            else  => { dest[out] = c; out += 1; },
        }
    }
    return out;
}

/// Send the initial SSE role chunk (OpenAI requires this as the first chunk).
fn sendSSERoleChunk(conn: *std.net.Server.Connection, request_id: []const u8, model: []const u8, created: i64) void {
    var buf: [1024]u8 = undefined;
    const json = std.fmt.bufPrint(&buf,
        \\data: {{"id":"{s}","object":"chat.completion.chunk","created":{d},"model":"{s}","choices":[{{"index":0,"delta":{{"role":"assistant","content":""}},"finish_reason":null}}]}}
        \\
        \\
    , .{ request_id, created, model }) catch return;
    _ = conn.stream.write(json) catch {};
}

/// Send SSE token event with model and created fields (OpenAI-compatible).
fn sendSSEToken(conn: *std.net.Server.Connection, token: []const u8, request_id: []const u8, model: []const u8, created: i64) !void {
    var buf: [4096]u8 = undefined;
    var escaped: [2048]u8 = undefined;
    const esc_len = jsonEscape(token, &escaped);

    const json = std.fmt.bufPrint(&buf,
        \\data: {{"id":"{s}","object":"chat.completion.chunk","created":{d},"model":"{s}","choices":[{{"index":0,"delta":{{"content":"{s}"}},"finish_reason":null}}]}}
        \\
        \\
    , .{ request_id, created, model, escaped[0..esc_len] }) catch return;

    _ = conn.stream.write(json) catch {};
}

/// Send the final SSE stop chunk before [DONE].
fn sendSSEStopChunk(conn: *std.net.Server.Connection, request_id: []const u8, model: []const u8, created: i64) void {
    var buf: [512]u8 = undefined;
    const json = std.fmt.bufPrint(&buf,
        \\data: {{"id":"{s}","object":"chat.completion.chunk","created":{d},"model":"{s}","choices":[{{"index":0,"delta":{{}},"finish_reason":"stop"}}]}}
        \\
        \\
    , .{ request_id, created, model }) catch return;
    _ = conn.stream.write(json) catch {};
}

/// Send SSE error event
fn sendSSEError(conn: *std.net.Server.Connection, message: []const u8) !void {
    var buf: [1024]u8 = undefined;
    const json = std.fmt.bufPrint(&buf,
        \\data: {{"error":{{"message":"{s}","type":"server_error"}}}}
        \\
        \\
    , .{message}) catch return;
    _ = conn.stream.write(json) catch {};
}

/// Send SSE done event
fn sendSSEDone(conn: *std.net.Server.Connection) !void {
    _ = conn.stream.write("data: [DONE]\n\n") catch {};
}

/// Generate non-streaming completion
const CompletionResult = struct {
    content: []const u8,
    prompt_tokens: usize,
    completion_tokens: usize,
};

fn handleCompletion(
    state: *ServerState,
    messages: []const ChatMessage,
    max_tokens: usize,
    temperature: f32,
    json_mode: bool,
) !CompletionResult {
    const allocator = state.allocator;

    // Format prompt
    const prompt = try formatChatML(allocator, messages, state.no_think);
    defer allocator.free(prompt);

    // Create context
    var cparams = llama.Context.defaultParams();
    cparams.n_ctx = state.context_size;
    cparams.n_batch = state.context_size;
    cparams.n_threads = state.n_threads;
    cparams.n_threads_batch = state.n_threads_batch;
    cparams.no_perf = true;

    const ctx = llama.Context.initWithModel(state.model, cparams) catch {
        return error.ContextCreationFailed;
    };
    defer ctx.deinit();

    // Setup sampler
    var sampler = llama.Sampler.initChain(.{ .no_perf = true });
    defer sampler.deinit();

    if (temperature == 0) {
        sampler.add(llama.Sampler.initGreedy());
    } else {
        sampler.add(llama.Sampler.initTopK(state.top_k));
        sampler.add(llama.Sampler.initTopP(state.top_p, 1));
        sampler.add(llama.Sampler.initTemp(temperature));
        sampler.add(llama.Sampler.initDist(0));
    }

    // Grammar-constrained sampling: when json_mode is requested, add a JSON
    // grammar sampler that sets -inf logits for tokens violating JSON syntax.
    if (json_mode) {
        const grammar_str = @import("../grammar.zig").JSON_GRAMMAR;
        sampler.add(llama.Sampler.initGrammar(state.vocab, grammar_str, "root"));
    }

    // Tokenize
    var tokenizer = llama.Tokenizer.init(allocator);
    defer tokenizer.deinit();
    try tokenizer.tokenize(state.vocab, prompt, false, true);
    const prompt_tokens = tokenizer.getTokens().len;

    var detokenizer = llama.Detokenizer.init(allocator);
    defer detokenizer.deinit();

    // Generate tokens
    var response: std.ArrayList(u8) = .empty;
    errdefer response.deinit(allocator);

    var batch = llama.Batch.initOne(tokenizer.getTokens());
    var batch_token: [1]llama.Token = undefined;
    var completion_tokens: usize = 0;

    for (0..max_tokens) |_| {
        batch.decode(ctx) catch break;
        const token = sampler.sample(ctx, -1);
        if (state.vocab.isEog(token)) break;

        batch_token[0] = token;
        batch = llama.Batch.initOne(batch_token[0..]);

        const token_text = detokenizer.detokenize(state.vocab, token) catch continue;
        try response.appendSlice(allocator, token_text);
        detokenizer.clearRetainingCapacity();
        completion_tokens += 1;
    }

    // Strip residual </think> prefix when --no-think is active.
    // The prompt prefills <think>\n\n</think>\n but the model sometimes
    // still emits </think> as the first generated token(s).
    var content = try response.toOwnedSlice(allocator);
    if (state.no_think) {
        const think_end = "</think>";
        var start: usize = 0;
        // Skip leading whitespace
        while (start < content.len and (content[start] == ' ' or content[start] == '\n' or content[start] == '\r' or content[start] == '\t')) : (start += 1) {}
        if (start + think_end.len <= content.len and std.mem.eql(u8, content[start .. start + think_end.len], think_end)) {
            var trim_start = start + think_end.len;
            // Skip whitespace after </think>
            while (trim_start < content.len and (content[trim_start] == ' ' or content[trim_start] == '\n' or content[trim_start] == '\r' or content[trim_start] == '\t')) : (trim_start += 1) {}
            const trimmed = try allocator.dupe(u8, content[trim_start..]);
            allocator.free(content);
            content = trimmed;
        }
    }

    return .{
        .content = content,
        .prompt_tokens = prompt_tokens,
        .completion_tokens = completion_tokens,
    };
}

/// Send HTTP response
fn sendResponse(conn: *std.net.Server.Connection, status: []const u8, content_type: []const u8, body: []const u8) void {
    var header_buf: [512]u8 = undefined;
    const header = std.fmt.bufPrint(
        &header_buf,
        "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n",
        .{ status, content_type, body.len },
    ) catch return;

    _ = conn.stream.write(header) catch {};
    _ = conn.stream.write(body) catch {};
}

/// Send SSE headers for streaming response
fn sendSSEHeaders(conn: *std.net.Server.Connection) void {
    const headers =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: text/event-stream\r\n" ++
        "Cache-Control: no-cache\r\n" ++
        "Connection: keep-alive\r\n" ++
        "Access-Control-Allow-Origin: *\r\n" ++
        "\r\n";
    _ = conn.stream.write(headers) catch {};
}

/// Handle a single HTTP request
fn handleRequest(state: *ServerState, conn: *std.net.Server.Connection) void {
    var buf: [65536]u8 = undefined;
    const bytes_read = conn.stream.read(&buf) catch return;
    if (bytes_read == 0) return;

    const request = buf[0..bytes_read];

    // Parse request line
    const request_line_end = std.mem.indexOf(u8, request, "\r\n") orelse return;
    const request_line = request[0..request_line_end];

    // Parse method and path
    var parts = std.mem.splitScalar(u8, request_line, ' ');
    const method = parts.next() orelse return;
    const path = parts.next() orelse return;

    // Handle CORS preflight
    if (std.mem.eql(u8, method, "OPTIONS")) {
        const cors_response =
            "HTTP/1.1 204 No Content\r\n" ++
            "Access-Control-Allow-Origin: *\r\n" ++
            "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n" ++
            "Access-Control-Allow-Headers: Content-Type, Authorization\r\n" ++
            "Access-Control-Max-Age: 86400\r\n" ++
            "\r\n";
        _ = conn.stream.write(cors_response) catch {};
        return;
    }

    // Route requests
    if (std.mem.eql(u8, path, "/health") or std.mem.eql(u8, path, "/")) {
        const health_json =
            \\{"status":"ok","model":"loaded"}
        ;
        sendResponse(conn, "200 OK", "application/json", health_json);
    } else if (std.mem.eql(u8, path, "/v1/models")) {
        var model_json_buf: [512]u8 = undefined;
        const model_json = std.fmt.bufPrint(&model_json_buf,
            \\{{"object":"list","data":[{{"id":"{s}","object":"model","owned_by":"local"}}]}}
        , .{state.model_name}) catch return;
        sendResponse(conn, "200 OK", "application/json", model_json);
    } else if (std.mem.eql(u8, path, "/v1/chat/completions")) {
        if (!std.mem.eql(u8, method, "POST")) {
            sendResponse(conn, "405 Method Not Allowed", "application/json", "{\"error\":\"Method not allowed\"}");
            return;
        }

        // Find request body (after \r\n\r\n)
        const body_start = std.mem.indexOf(u8, request, "\r\n\r\n") orelse return;
        const body = request[body_start + 4 ..];

        // Parse request
        var parsed = parseChatRequest(state.allocator, body) catch {
            sendResponse(conn, "400 Bad Request", "application/json", "{\"error\":\"Invalid request body\"}");
            return;
        };
        defer parsed.messages.deinit(state.allocator);

        if (parsed.messages.items.len == 0) {
            sendResponse(conn, "400 Bad Request", "application/json", "{\"error\":\"No messages provided\"}");
            return;
        }

        const max_tokens = parsed.max_tokens orelse state.max_tokens;
        const temperature = parsed.temperature orelse state.temperature;

        // Generate unique request ID
        var id_buf: [32]u8 = undefined;
        const timestamp = std.time.timestamp();
        const request_id = std.fmt.bufPrint(&id_buf, "chatcmpl-{d}", .{timestamp}) catch "chatcmpl-0";

        if (parsed.stream) {
            // Streaming response
            sendSSEHeaders(conn);
            handleStreamingCompletion(state, conn, parsed.messages.items, max_tokens, temperature, request_id, parsed.json_mode) catch {};
        } else {
            // Non-streaming response
            const completion = handleCompletion(state, parsed.messages.items, max_tokens, temperature, parsed.json_mode) catch {
                sendResponse(conn, "500 Internal Server Error", "application/json", "{\"error\":\"Generation failed\"}");
                return;
            };
            defer state.allocator.free(completion.content);

            // Escape content for JSON
            var escaped_content: std.ArrayList(u8) = .empty;
            defer escaped_content.deinit(state.allocator);

            for (completion.content) |c| {
                switch (c) {
                    '"' => escaped_content.appendSlice(state.allocator, "\\\"") catch {},
                    '\\' => escaped_content.appendSlice(state.allocator, "\\\\") catch {},
                    '\n' => escaped_content.appendSlice(state.allocator, "\\n") catch {},
                    '\r' => escaped_content.appendSlice(state.allocator, "\\r") catch {},
                    '\t' => escaped_content.appendSlice(state.allocator, "\\t") catch {},
                    else => escaped_content.append(state.allocator, c) catch {},
                }
            }

            // Build response JSON
            const created_ts = std.time.timestamp();
            var response_buf: [65536]u8 = undefined;
            const response_json = std.fmt.bufPrint(&response_buf,
                \\{{"id":"{s}","object":"chat.completion","created":{d},"model":"{s}","choices":[{{"index":0,"message":{{"role":"assistant","content":"{s}"}},"finish_reason":"stop"}}],"usage":{{"prompt_tokens":{d},"completion_tokens":{d},"total_tokens":{d}}}}}
            , .{
                request_id, created_ts, state.model_name, escaped_content.items,
                completion.prompt_tokens, completion.completion_tokens,
                completion.prompt_tokens + completion.completion_tokens,
            }) catch {
                sendResponse(conn, "500 Internal Server Error", "application/json", "{\"error\":\"Response too large\"}");
                return;
            };

            sendResponse(conn, "200 OK", "application/json", response_json);
        }
    } else if (std.mem.eql(u8, path, "/v1/embeddings")) {
        if (!std.mem.eql(u8, method, "POST")) {
            sendResponse(conn, "405 Method Not Allowed", "application/json", "{\"error\":\"Method not allowed\"}");
            return;
        }

        // Find request body
        const body_start = std.mem.indexOf(u8, request, "\r\n\r\n") orelse return;
        const body = request[body_start + 4 ..];

        // Parse request
        var parsed = parseEmbeddingsRequest(state.allocator, body) catch {
            sendResponse(conn, "400 Bad Request", "application/json", "{\"error\":\"Invalid request body\"}");
            return;
        };
        defer parsed.inputs.deinit(state.allocator);

        if (parsed.inputs.items.len == 0) {
            sendResponse(conn, "400 Bad Request", "application/json", "{\"error\":\"No input provided\"}");
            return;
        }

        // Generate embeddings
        var result = handleEmbeddings(state, parsed.inputs.items) catch {
            sendResponse(conn, "500 Internal Server Error", "application/json", "{\"error\":\"Embedding generation failed\"}");
            return;
        };
        defer {
            for (result.embeddings.items) |*e| e.deinit(state.allocator);
            result.embeddings.deinit(state.allocator);
        }

        // Build response JSON
        var response: std.ArrayList(u8) = .empty;
        defer response.deinit(state.allocator);

        response.appendSlice(state.allocator, "{\"object\":\"list\",\"data\":[") catch {
            sendResponse(conn, "500 Internal Server Error", "application/json", "{\"error\":\"Response building failed\"}");
            return;
        };

        for (result.embeddings.items, 0..) |embd, idx| {
            if (idx > 0) {
                response.appendSlice(state.allocator, ",") catch {};
            }

            // Start embedding object
            var obj_buf: [128]u8 = undefined;
            const obj_start = std.fmt.bufPrint(&obj_buf, "{{\"object\":\"embedding\",\"index\":{d},\"embedding\":[", .{idx}) catch continue;
            response.appendSlice(state.allocator, obj_start) catch continue;

            // Add embedding values
            for (embd.items, 0..) |val, i| {
                if (i > 0) {
                    response.appendSlice(state.allocator, ",") catch {};
                }
                var val_buf: [32]u8 = undefined;
                const val_str = std.fmt.bufPrint(&val_buf, "{d:.6}", .{val}) catch continue;
                response.appendSlice(state.allocator, val_str) catch {};
            }

            response.appendSlice(state.allocator, "]}") catch {};
        }

        // Close array and add usage
        var usage_buf: [128]u8 = undefined;
        const usage = std.fmt.bufPrint(&usage_buf, "],\"model\":\"{s}\",\"usage\":{{\"prompt_tokens\":{d},\"total_tokens\":{d}}}}}", .{
            state.model_name,
            result.total_tokens,
            result.total_tokens,
        }) catch {
            sendResponse(conn, "500 Internal Server Error", "application/json", "{\"error\":\"Response building failed\"}");
            return;
        };
        response.appendSlice(state.allocator, usage) catch {};

        sendResponse(conn, "200 OK", "application/json", response.items);
    } else {
        sendResponse(conn, "404 Not Found", "application/json", "{\"error\":\"Not found\"}");
    }
}

pub fn run(args: []const []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Setup stdout/stderr
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
    var port: u16 = 8080;
    var host: []const u8 = "127.0.0.1";
    var gpu_layers: i32 = 0;
    var context_size: u32 = 4096;
    var temperature: f32 = 0.7;
    const top_p: f32 = 0.9;
    const top_k: i32 = 40;
    var max_tokens: usize = 2048;
    const cpu_count: i32 = @intCast(std.Thread.getCpuCount() catch 4);
    var n_threads: i32 = cpu_count;
    var n_threads_batch: i32 = cpu_count;
    var use_mlock: bool = false;
    var no_think: bool = false;

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
        } else if (std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "-p")) {
            if (i + 1 < args.len) {
                port = std.fmt.parseInt(u16, args[i + 1], 10) catch 8080;
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--host") or std.mem.eql(u8, arg, "-h")) {
            if (i + 1 < args.len) {
                host = args[i + 1];
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--gpu-layers") or std.mem.eql(u8, arg, "-ngl")) {
            if (i + 1 < args.len) {
                gpu_layers = std.fmt.parseInt(i32, args[i + 1], 10) catch 0;
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--ctx-size") or std.mem.eql(u8, arg, "-c")) {
            if (i + 1 < args.len) {
                context_size = std.fmt.parseInt(u32, args[i + 1], 10) catch 4096;
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--max-tokens") or std.mem.eql(u8, arg, "-n")) {
            if (i + 1 < args.len) {
                max_tokens = std.fmt.parseInt(usize, args[i + 1], 10) catch 2048;
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--temp")) {
            if (i + 1 < args.len) {
                temperature = std.fmt.parseFloat(f32, args[i + 1]) catch 0.7;
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--threads") or std.mem.eql(u8, arg, "-t")) {
            if (i + 1 < args.len) {
                n_threads = std.fmt.parseInt(i32, args[i + 1], 10) catch cpu_count;
                n_threads_batch = n_threads;
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--threads-batch") or std.mem.eql(u8, arg, "-tb")) {
            if (i + 1 < args.len) {
                n_threads_batch = std.fmt.parseInt(i32, args[i + 1], 10) catch cpu_count;
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--mlock")) {
            use_mlock = true;
        } else if (std.mem.eql(u8, arg, "--no-think")) {
            no_think = true;
        } else if (std.mem.eql(u8, arg, "--help")) {
            try printHelp(stdout);
            return;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            const path_z = try allocator.allocSentinel(u8, arg.len, 0);
            @memcpy(path_z, arg);
            model_path = path_z;
        }
    }

    if (model_path == null) {
        try stderr.print("Error: Model path required\n\n", .{});
        try printHelp(stderr);
        return error.InvalidArguments;
    }

    defer if (model_path) |p| allocator.free(p);

    // Validate GGUF
    const validation = gguf.validateFile(model_path.?);
    if (!validation.valid) {
        try stderr.print("Error: Invalid model file: {s}\n", .{validation.error_message orelse "Unknown error"});
        return error.InvalidGgufFile;
    }

    try stdout.print("\n{s} API Server v{s}\n", .{ config.app_name, config.version });
    try stdout.print("Loading model: {s}\n", .{model_path.?});
    try stdout.flush();

    // Initialize llama backend
    llama.Backend.init();
    defer llama.Backend.deinit();

    // Load model
    var mparams = llama.Model.defaultParams();
    mparams.n_gpu_layers = gpu_layers;
    mparams.use_mlock = use_mlock;

    const model = llama.Model.initFromFile(model_path.?.ptr, mparams) catch |err| {
        try stderr.print("Error loading model: {}\n", .{err});
        return err;
    };

    const vocab = model.vocab() orelse {
        model.deinit();
        try stderr.print("Error: Model missing vocabulary\n", .{});
        return error.MissingVocabulary;
    };

    // Extract model name from path
    const model_name = blk: {
        const path_slice = model_path.?;
        const basename = std.fs.path.basename(path_slice);
        break :blk try allocator.dupe(u8, basename);
    };

    var state = ServerState{
        .allocator = allocator,
        .model = model,
        .vocab = vocab,
        .model_name = model_name,
        .context_size = context_size,
        .temperature = temperature,
        .top_p = top_p,
        .top_k = top_k,
        .max_tokens = max_tokens,
        .n_threads = n_threads,
        .n_threads_batch = n_threads_batch,
        .no_think = no_think,
    };
    defer state.deinit();

    try stdout.print("Model loaded successfully\n\n", .{});
    try stdout.print("Starting server on {s}:{d}\n", .{ host, port });
    try stdout.print("Endpoints:\n", .{});
    try stdout.print("  GET  /health              - Health check\n", .{});
    try stdout.print("  GET  /v1/models           - List models\n", .{});
    try stdout.print("  POST /v1/chat/completions - Chat completions (OpenAI-compatible)\n", .{});
    try stdout.print("\nPress Ctrl+C to stop\n\n", .{});
    try stdout.flush();

    // Parse address
    const addr = std.net.Address.parseIp4(host, port) catch {
        try stderr.print("Error: Invalid host address\n", .{});
        return error.InvalidAddress;
    };

    // Start server
    var server = addr.listen(.{ .reuse_address = true }) catch |err| {
        try stderr.print("Error binding to {s}:{d}: {}\n", .{ host, port, err });
        return err;
    };
    defer server.deinit();

    try stdout.print("Server listening on http://{s}:{d}\n", .{ host, port });
    try stdout.flush();

    // Accept connections
    while (true) {
        var conn = server.accept() catch continue;
        defer conn.stream.close();

        handleRequest(&state, &conn);
    }
}

fn printHelp(writer: anytype) !void {
    try writer.print(
        \\igllama api - Native API server with OpenAI-compatible endpoints
        \\
        \\Usage:
        \\  igllama api <model.gguf> [options]
        \\
        \\Options:
        \\  -m, --model <path>        Path to GGUF model file (required)
        \\  -p, --port <num>          Server port (default: 8080)
        \\  -h, --host <addr>         Server host (default: 127.0.0.1)
        \\  -c, --ctx-size <num>      Context size (default: 4096)
        \\  -n, --max-tokens <num>    Max tokens per response (default: 2048)
        \\  -ngl, --gpu-layers <n>    GPU layers to offload (default: 0)
        \\  -t, --threads <n>         Generation threads (default: all CPU cores)
        \\  -tb, --threads-batch <n>  Prompt eval threads (default: all CPU cores)
        \\  --mlock                   Pin model weights in RAM (prevents paging)
        \\  --no-think                Suppress <think> reasoning blocks (Qwen3-style models)
        \\  --temp <float>            Temperature (default: 0.7)
        \\  --help                    Show this help
        \\
        \\Performance Tips (CPU-only):
        \\  - Set --threads to match your CPU's memory channel count for best generation speed
        \\  - Set --threads-batch to your total core count for fastest prompt processing
        \\  - Use --mlock to prevent model paging when RAM is sufficient
        \\  - Example (16-core server, 8 memory channels):
        \\    igllama api model.gguf --threads 8 --threads-batch 16 --mlock --ctx-size 8192
        \\
        \\Examples:
        \\  igllama api model.gguf
        \\  igllama api model.gguf --port 8080 --gpu-layers 35
        \\  igllama api model.gguf --threads 8 --threads-batch 16 --mlock
        \\  igllama api model.gguf --no-think
        \\
        \\API Usage:
        \\  # Health check
        \\  curl http://127.0.0.1:8080/health
        \\
        \\  # Non-streaming chat completion
        \\  curl http://127.0.0.1:8080/v1/chat/completions \
        \\    -H "Content-Type: application/json" \
        \\    -d '{{"messages":[{{"role":"user","content":"Hello!"}}]}}'
        \\
        \\  # Streaming chat completion (SSE)
        \\  curl http://127.0.0.1:8080/v1/chat/completions \
        \\    -H "Content-Type: application/json" \
        \\    -d '{{"messages":[{{"role":"user","content":"Hello!"}}],"stream":true}}'
        \\
    , .{});
}
