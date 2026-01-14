const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");

/// Session metadata for observability and management
pub const SessionMetadata = struct {
    version: []const u8 = "1.0",
    model: []const u8,
    template: []const u8,
    context_size: u32,
    created_at: i64,
    updated_at: i64,
    total_turns: usize,
    total_tokens_estimated: usize,
};

/// Individual message with timestamp and optional metrics
pub const SessionMessage = struct {
    role: []const u8,
    content: []const u8,
    timestamp: i64,
    // Optional metrics for assistant messages
    generation_time_ms: ?u64 = null,
    tokens_generated: ?usize = null,
};

/// Brief info about a saved session for listing
pub const SessionInfo = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    model: []const u8,
    template: []const u8,
    created_at: i64,
    updated_at: i64,
    turn_count: usize,

    pub fn deinit(self: *SessionInfo) void {
        self.allocator.free(self.name);
        self.allocator.free(self.model);
        self.allocator.free(self.template);
    }
};

/// Manages conversation session persistence
pub const SessionManager = struct {
    allocator: std.mem.Allocator,
    sessions_dir: []const u8,
    sessions_dir_owned: bool,

    const Self = @This();

    /// Initialize the session manager with default sessions directory
    pub fn init(allocator: std.mem.Allocator) !Self {
        var cfg = try config.Config.init(allocator);
        defer cfg.deinit();

        const sessions_dir = try std.fs.path.join(allocator, &.{ cfg.home_dir, "sessions" });

        // Create directory if it doesn't exist
        std.fs.cwd().makePath(sessions_dir) catch |err| {
            if (err != error.PathAlreadyExists) {
                allocator.free(sessions_dir);
                return err;
            }
        };

        return Self{
            .allocator = allocator,
            .sessions_dir = sessions_dir,
            .sessions_dir_owned = true,
        };
    }

    /// Initialize with a custom sessions directory
    pub fn initWithDir(allocator: std.mem.Allocator, sessions_dir: []const u8) !Self {
        // Create directory if it doesn't exist
        std.fs.cwd().makePath(sessions_dir) catch |err| {
            if (err != error.PathAlreadyExists) {
                return err;
            }
        };

        return Self{
            .allocator = allocator,
            .sessions_dir = sessions_dir,
            .sessions_dir_owned = false,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.sessions_dir_owned) {
            self.allocator.free(self.sessions_dir);
        }
    }

    /// Generate a session filename based on model and timestamp
    /// Format: {model_basename}_{YYYYMMDD_HHMMSS}.json
    pub fn generateSessionName(self: *Self, model: []const u8, timestamp: i64) ![]const u8 {
        // Get model basename (without path and extension)
        var model_name = std.fs.path.basename(model);
        if (std.mem.lastIndexOf(u8, model_name, ".")) |dot_idx| {
            model_name = model_name[0..dot_idx];
        }

        // Truncate long model names
        const max_model_len: usize = 40;
        if (model_name.len > max_model_len) {
            model_name = model_name[0..max_model_len];
        }

        // Convert timestamp to datetime components
        const epoch_seconds: u64 = @intCast(timestamp);
        const epoch_day = epoch_seconds / 86400;
        const day_seconds = epoch_seconds % 86400;

        // Calculate date (simplified - accurate enough for filenames)
        var year: u32 = 1970;
        var remaining_days: u64 = epoch_day;

        while (true) {
            const days_in_year: u64 = if (isLeapYear(year)) 366 else 365;
            if (remaining_days < days_in_year) break;
            remaining_days -= days_in_year;
            year += 1;
        }

        // Month and day
        const month_days = if (isLeapYear(year))
            [_]u8{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
        else
            [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

        var month: u8 = 1;
        for (month_days) |days| {
            if (remaining_days < days) break;
            remaining_days -= days;
            month += 1;
        }
        const day: u8 = @intCast(remaining_days + 1);

        // Time
        const hour: u8 = @intCast(day_seconds / 3600);
        const minute: u8 = @intCast((day_seconds % 3600) / 60);
        const second: u8 = @intCast(day_seconds % 60);

        // Format filename
        var buf: [128]u8 = undefined;
        const formatted = std.fmt.bufPrint(&buf, "{s}_{d:0>4}{d:0>2}{d:0>2}_{d:0>2}{d:0>2}{d:0>2}.json", .{
            model_name,
            year,
            month,
            day,
            hour,
            minute,
            second,
        }) catch return error.BufferTooSmall;

        return try self.allocator.dupe(u8, formatted);
    }

    fn isLeapYear(year: u32) bool {
        return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
    }

    /// Save a session to disk
    pub fn saveSession(
        self: *Self,
        session_name: []const u8,
        metadata: SessionMetadata,
        system_prompt: []const u8,
        messages: []const SessionMessage,
    ) !void {
        const file_path = try std.fs.path.join(self.allocator, &.{ self.sessions_dir, session_name });
        defer self.allocator.free(file_path);

        var file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();

        // Write JSON manually for full control over format
        var content: std.ArrayList(u8) = .empty;
        defer content.deinit(self.allocator);

        try content.appendSlice(self.allocator, "{\n");

        // Metadata section
        try content.appendSlice(self.allocator, "  \"metadata\": {\n");
        try content.appendSlice(self.allocator, "    \"version\": \"");
        try content.appendSlice(self.allocator, metadata.version);
        try content.appendSlice(self.allocator, "\",\n");

        try content.appendSlice(self.allocator, "    \"model\": \"");
        try appendJsonEscaped(&content, self.allocator, metadata.model);
        try content.appendSlice(self.allocator, "\",\n");

        try content.appendSlice(self.allocator, "    \"template\": \"");
        try appendJsonEscaped(&content, self.allocator, metadata.template);
        try content.appendSlice(self.allocator, "\",\n");

        var buf: [64]u8 = undefined;

        try content.appendSlice(self.allocator, "    \"context_size\": ");
        try content.appendSlice(self.allocator, std.fmt.bufPrint(&buf, "{d}", .{metadata.context_size}) catch "0");
        try content.appendSlice(self.allocator, ",\n");

        try content.appendSlice(self.allocator, "    \"created_at\": ");
        try content.appendSlice(self.allocator, std.fmt.bufPrint(&buf, "{d}", .{metadata.created_at}) catch "0");
        try content.appendSlice(self.allocator, ",\n");

        try content.appendSlice(self.allocator, "    \"updated_at\": ");
        try content.appendSlice(self.allocator, std.fmt.bufPrint(&buf, "{d}", .{metadata.updated_at}) catch "0");
        try content.appendSlice(self.allocator, ",\n");

        try content.appendSlice(self.allocator, "    \"total_turns\": ");
        try content.appendSlice(self.allocator, std.fmt.bufPrint(&buf, "{d}", .{metadata.total_turns}) catch "0");
        try content.appendSlice(self.allocator, ",\n");

        try content.appendSlice(self.allocator, "    \"total_tokens_estimated\": ");
        try content.appendSlice(self.allocator, std.fmt.bufPrint(&buf, "{d}", .{metadata.total_tokens_estimated}) catch "0");
        try content.appendSlice(self.allocator, "\n");

        try content.appendSlice(self.allocator, "  },\n");

        // System prompt
        try content.appendSlice(self.allocator, "  \"system_prompt\": \"");
        try appendJsonEscaped(&content, self.allocator, system_prompt);
        try content.appendSlice(self.allocator, "\",\n");

        // Messages array
        try content.appendSlice(self.allocator, "  \"messages\": [\n");

        for (messages, 0..) |msg, i| {
            try content.appendSlice(self.allocator, "    {\n");

            try content.appendSlice(self.allocator, "      \"role\": \"");
            try content.appendSlice(self.allocator, msg.role);
            try content.appendSlice(self.allocator, "\",\n");

            try content.appendSlice(self.allocator, "      \"content\": \"");
            try appendJsonEscaped(&content, self.allocator, msg.content);
            try content.appendSlice(self.allocator, "\",\n");

            try content.appendSlice(self.allocator, "      \"timestamp\": ");
            try content.appendSlice(self.allocator, std.fmt.bufPrint(&buf, "{d}", .{msg.timestamp}) catch "0");

            if (msg.generation_time_ms) |time_ms| {
                try content.appendSlice(self.allocator, ",\n      \"generation_time_ms\": ");
                try content.appendSlice(self.allocator, std.fmt.bufPrint(&buf, "{d}", .{time_ms}) catch "0");
            }

            if (msg.tokens_generated) |tokens| {
                try content.appendSlice(self.allocator, ",\n      \"tokens_generated\": ");
                try content.appendSlice(self.allocator, std.fmt.bufPrint(&buf, "{d}", .{tokens}) catch "0");
            }

            try content.appendSlice(self.allocator, "\n    }");

            if (i < messages.len - 1) {
                try content.appendSlice(self.allocator, ",");
            }
            try content.appendSlice(self.allocator, "\n");
        }

        try content.appendSlice(self.allocator, "  ]\n");
        try content.appendSlice(self.allocator, "}\n");

        try file.writeAll(content.items);
    }

    /// List all saved sessions
    pub fn listSessions(self: *Self) !std.ArrayList(SessionInfo) {
        var sessions: std.ArrayList(SessionInfo) = .empty;
        errdefer {
            for (sessions.items) |*s| s.deinit();
            sessions.deinit(self.allocator);
        }

        var dir = std.fs.cwd().openDir(self.sessions_dir, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) {
                return sessions;
            }
            return err;
        };
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

            // Try to parse session info from file
            if (self.parseSessionInfo(entry.name)) |info| {
                try sessions.append(self.allocator, info);
            } else |_| {
                // Skip files that can't be parsed
                continue;
            }
        }

        return sessions;
    }

    /// Parse session info from a file (quick metadata extraction)
    fn parseSessionInfo(self: *Self, filename: []const u8) !SessionInfo {
        const file_path = try std.fs.path.join(self.allocator, &.{ self.sessions_dir, filename });
        defer self.allocator.free(file_path);

        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        // Read just the first 4KB to get metadata
        var buffer: [4096]u8 = undefined;
        const bytes_read = try file.read(&buffer);
        const content = buffer[0..bytes_read];

        // Extract fields from JSON
        const model = findJsonStringValue(content, "\"model\"") orelse "unknown";
        const template = findJsonStringValue(content, "\"template\"") orelse "unknown";
        const created_at = findJsonNumber(content, "\"created_at\"") orelse 0;
        const updated_at = findJsonNumber(content, "\"updated_at\"") orelse 0;
        const total_turns = findJsonNumber(content, "\"total_turns\"") orelse 0;

        return SessionInfo{
            .allocator = self.allocator,
            .name = try self.allocator.dupe(u8, filename),
            .model = try self.allocator.dupe(u8, model),
            .template = try self.allocator.dupe(u8, template),
            .created_at = @intFromFloat(created_at),
            .updated_at = @intFromFloat(updated_at),
            .turn_count = @intFromFloat(total_turns),
        };
    }

    /// Delete a session file
    pub fn deleteSession(self: *Self, session_name: []const u8) !void {
        const file_path = try std.fs.path.join(self.allocator, &.{ self.sessions_dir, session_name });
        defer self.allocator.free(file_path);

        try std.fs.cwd().deleteFile(file_path);
    }

    /// Get full path to a session file
    pub fn getSessionPath(self: *Self, session_name: []const u8) ![]const u8 {
        return try std.fs.path.join(self.allocator, &.{ self.sessions_dir, session_name });
    }
};

// JSON parsing helpers (reused from config.zig pattern)

fn findJsonStringValue(content: []const u8, key: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, content, key)) |key_start| {
        var search_pos = key_start + key.len;
        // Skip to colon
        while (search_pos < content.len and content[search_pos] != ':') : (search_pos += 1) {}
        search_pos += 1;
        // Skip whitespace
        while (search_pos < content.len and (content[search_pos] == ' ' or content[search_pos] == '\n' or content[search_pos] == '\t')) : (search_pos += 1) {}
        // Check for string start
        if (search_pos < content.len and content[search_pos] == '"') {
            search_pos += 1;
            const str_start = search_pos;
            // Find end of string (handling escapes)
            while (search_pos < content.len) {
                if (content[search_pos] == '\\' and search_pos + 1 < content.len) {
                    search_pos += 2;
                } else if (content[search_pos] == '"') {
                    return content[str_start..search_pos];
                } else {
                    search_pos += 1;
                }
            }
        }
    }
    return null;
}

fn findJsonNumber(content: []const u8, key: []const u8) ?f64 {
    if (std.mem.indexOf(u8, content, key)) |key_start| {
        var search_pos = key_start + key.len;
        // Skip to colon
        while (search_pos < content.len and content[search_pos] != ':') : (search_pos += 1) {}
        search_pos += 1;
        // Skip whitespace
        while (search_pos < content.len and (content[search_pos] == ' ' or content[search_pos] == '\n' or content[search_pos] == '\t')) : (search_pos += 1) {}
        // Find number end
        const num_start = search_pos;
        while (search_pos < content.len and (content[search_pos] >= '0' and content[search_pos] <= '9' or content[search_pos] == '.' or content[search_pos] == '-')) : (search_pos += 1) {}
        if (num_start < search_pos) {
            return std.fmt.parseFloat(f64, content[num_start..search_pos]) catch null;
        }
    }
    return null;
}

fn appendJsonEscaped(list: *std.ArrayList(u8), allocator: std.mem.Allocator, str: []const u8) !void {
    for (str) |c| {
        switch (c) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            else => {
                // Handle control characters
                if (c < 0x20) {
                    var hex_buf: [6]u8 = undefined;
                    const hex = std.fmt.bufPrint(&hex_buf, "\\u{X:0>4}", .{c}) catch continue;
                    try list.appendSlice(allocator, hex);
                } else {
                    try list.append(allocator, c);
                }
            },
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

test "SessionManager.generateSessionName creates valid filename" {
    const allocator = std.testing.allocator;

    // Create a temporary session manager
    var manager = SessionManager{
        .allocator = allocator,
        .sessions_dir = "/tmp/test-sessions",
        .sessions_dir_owned = false,
    };

    // Test with a sample timestamp (2026-01-14 15:30:00 UTC)
    // Note: 2026-01-14 is day 20467 since epoch (1970-01-01)
    const timestamp: i64 = 1768502400; // Approximate timestamp for 2026-01-14

    const name = try manager.generateSessionName("tinyllama-1.1b-chat.Q4_K_M.gguf", timestamp);
    defer allocator.free(name);

    // Check format
    try std.testing.expect(std.mem.startsWith(u8, name, "tinyllama-1.1b-chat.Q4_K_M_"));
    try std.testing.expect(std.mem.endsWith(u8, name, ".json"));
}

test "appendJsonEscaped escapes special characters" {
    const allocator = std.testing.allocator;

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);

    try appendJsonEscaped(&list, allocator, "Hello\n\"World\"\\!");

    try std.testing.expectEqualStrings("Hello\\n\\\"World\\\"\\\\!", list.items);
}
