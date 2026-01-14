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
} {
    var messages: std.ArrayList(ChatMessage) = .empty;
    var stream = false;
    var max_tokens: ?usize = null;
    var temperature: ?f32 = null;

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
        if (pos >= body.len) return .{ .messages = messages, .stream = stream, .max_tokens = max_tokens, .temperature = temperature };
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

    return .{ .messages = messages, .stream = stream, .max_tokens = max_tokens, .temperature = temperature };
}

/// Format messages using ChatML template
fn formatChatML(allocator: std.mem.Allocator, messages: []const ChatMessage) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    for (messages) |msg| {
        try result.appendSlice(allocator, "<|im_start|>");
        try result.appendSlice(allocator, msg.role);
        try result.appendSlice(allocator, "\n");
        try result.appendSlice(allocator, msg.content);
        try result.appendSlice(allocator, "<|im_end|>\n");
    }

    try result.appendSlice(allocator, "<|im_start|>assistant\n");

    return result.toOwnedSlice(allocator);
}

/// Generate completion and write SSE events to connection
fn handleStreamingCompletion(
    state: *ServerState,
    conn: *std.net.Server.Connection,
    messages: []const ChatMessage,
    max_tokens: usize,
    temperature: f32,
    request_id: []const u8,
) !void {
    const allocator = state.allocator;

    // Format prompt
    const prompt = try formatChatML(allocator, messages);
    defer allocator.free(prompt);

    // Create context for this request
    var cparams = llama.Context.defaultParams();
    cparams.n_ctx = state.context_size;
    const cpu_threads = std.Thread.getCpuCount() catch 4;
    cparams.n_threads = @intCast(@min(cpu_threads, 4));
    cparams.n_threads_batch = @intCast(cpu_threads / 2);
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

    // Tokenize
    var tokenizer = llama.Tokenizer.init(allocator);
    defer tokenizer.deinit();
    try tokenizer.tokenize(state.vocab, prompt, false, true);

    var detokenizer = llama.Detokenizer.init(allocator);
    defer detokenizer.deinit();

    // Generate tokens
    var batch = llama.Batch.initOne(tokenizer.getTokens());
    var batch_token: [1]llama.Token = undefined;

    for (0..max_tokens) |_| {
        batch.decode(ctx) catch break;
        const token = sampler.sample(ctx, -1);
        if (state.vocab.isEog(token)) break;

        batch_token[0] = token;
        batch = llama.Batch.initOne(batch_token[0..]);

        // Detokenize and send SSE event
        const token_text = detokenizer.detokenize(state.vocab, token) catch continue;

        // Send SSE data event
        try sendSSEToken(conn, token_text, request_id);
        detokenizer.clearRetainingCapacity();
    }

    // Send final [DONE] event
    try sendSSEDone(conn);
}

/// Send SSE token event
fn sendSSEToken(conn: *std.net.Server.Connection, token: []const u8, request_id: []const u8) !void {
    var buf: [4096]u8 = undefined;

    // Escape token for JSON
    var escaped: [2048]u8 = undefined;
    var esc_len: usize = 0;
    for (token) |c| {
        if (esc_len + 2 >= escaped.len) break;
        switch (c) {
            '"' => {
                escaped[esc_len] = '\\';
                escaped[esc_len + 1] = '"';
                esc_len += 2;
            },
            '\\' => {
                escaped[esc_len] = '\\';
                escaped[esc_len + 1] = '\\';
                esc_len += 2;
            },
            '\n' => {
                escaped[esc_len] = '\\';
                escaped[esc_len + 1] = 'n';
                esc_len += 2;
            },
            '\r' => {
                escaped[esc_len] = '\\';
                escaped[esc_len + 1] = 'r';
                esc_len += 2;
            },
            '\t' => {
                escaped[esc_len] = '\\';
                escaped[esc_len + 1] = 't';
                esc_len += 2;
            },
            else => {
                escaped[esc_len] = c;
                esc_len += 1;
            },
        }
    }

    const json = std.fmt.bufPrint(&buf,
        \\data: {{"id":"{s}","object":"chat.completion.chunk","choices":[{{"index":0,"delta":{{"content":"{s}"}},"finish_reason":null}}]}}
        \\
        \\
    , .{ request_id, escaped[0..esc_len] }) catch return;

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
fn handleCompletion(
    state: *ServerState,
    messages: []const ChatMessage,
    max_tokens: usize,
    temperature: f32,
) ![]const u8 {
    const allocator = state.allocator;

    // Format prompt
    const prompt = try formatChatML(allocator, messages);
    defer allocator.free(prompt);

    // Create context
    var cparams = llama.Context.defaultParams();
    cparams.n_ctx = state.context_size;
    const cpu_threads = std.Thread.getCpuCount() catch 4;
    cparams.n_threads = @intCast(@min(cpu_threads, 4));
    cparams.n_threads_batch = @intCast(cpu_threads / 2);
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

    // Tokenize
    var tokenizer = llama.Tokenizer.init(allocator);
    defer tokenizer.deinit();
    try tokenizer.tokenize(state.vocab, prompt, false, true);

    var detokenizer = llama.Detokenizer.init(allocator);
    defer detokenizer.deinit();

    // Generate tokens
    var response: std.ArrayList(u8) = .empty;
    errdefer response.deinit(allocator);

    var batch = llama.Batch.initOne(tokenizer.getTokens());
    var batch_token: [1]llama.Token = undefined;

    for (0..max_tokens) |_| {
        batch.decode(ctx) catch break;
        const token = sampler.sample(ctx, -1);
        if (state.vocab.isEog(token)) break;

        batch_token[0] = token;
        batch = llama.Batch.initOne(batch_token[0..]);

        const token_text = detokenizer.detokenize(state.vocab, token) catch continue;
        try response.appendSlice(allocator, token_text);
        detokenizer.clearRetainingCapacity();
    }

    return response.toOwnedSlice(allocator);
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
            handleStreamingCompletion(state, conn, parsed.messages.items, max_tokens, temperature, request_id) catch {};
        } else {
            // Non-streaming response
            const response_content = handleCompletion(state, parsed.messages.items, max_tokens, temperature) catch {
                sendResponse(conn, "500 Internal Server Error", "application/json", "{\"error\":\"Generation failed\"}");
                return;
            };
            defer state.allocator.free(response_content);

            // Escape content for JSON
            var escaped_content: std.ArrayList(u8) = .empty;
            defer escaped_content.deinit(state.allocator);

            for (response_content) |c| {
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
            var response_buf: [65536]u8 = undefined;
            const response_json = std.fmt.bufPrint(&response_buf,
                \\{{"id":"{s}","object":"chat.completion","choices":[{{"index":0,"message":{{"role":"assistant","content":"{s}"}},"finish_reason":"stop"}}],"usage":{{"prompt_tokens":0,"completion_tokens":0,"total_tokens":0}}}}
            , .{ request_id, escaped_content.items }) catch {
                sendResponse(conn, "500 Internal Server Error", "application/json", "{\"error\":\"Response too large\"}");
                return;
            };

            sendResponse(conn, "200 OK", "application/json", response_json);
        }
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
        \\  -m, --model <path>      Path to GGUF model file (required)
        \\  -p, --port <num>        Server port (default: 8080)
        \\  -h, --host <addr>       Server host (default: 127.0.0.1)
        \\  -c, --ctx-size <num>    Context size (default: 4096)
        \\  -n, --max-tokens <num>  Max tokens per response (default: 2048)
        \\  -ngl, --gpu-layers <n>  GPU layers to offload (default: 0)
        \\  --temp <float>          Temperature (default: 0.7)
        \\  --help                  Show this help
        \\
        \\Examples:
        \\  igllama api model.gguf
        \\  igllama api model.gguf --port 8080 --gpu-layers 35
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
