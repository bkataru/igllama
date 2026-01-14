const std = @import("std");
const builtin = @import("builtin");

/// Per-model configuration overrides
pub const ModelConfig = struct {
    allocator: std.mem.Allocator,

    // Model identification
    model_path: []const u8,
    model_path_owned: bool = false,

    // Overrides (null means use global default)
    gpu_layers: ?i32 = null,
    context_size: ?u32 = null,
    max_tokens: ?usize = null,
    template: ?[]const u8 = null,
    template_owned: bool = false,
    system_prompt: ?[]const u8 = null,
    system_prompt_owned: bool = false,

    // Sampling overrides
    temperature: ?f32 = null,
    top_p: ?f32 = null,
    top_k: ?i32 = null,
    repeat_penalty: ?f32 = null,

    // Grammar file
    grammar_file: ?[]const u8 = null,
    grammar_file_owned: bool = false,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, model_path: []const u8) !Self {
        return .{
            .allocator = allocator,
            .model_path = try allocator.dupe(u8, model_path),
            .model_path_owned = true,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.model_path_owned) {
            self.allocator.free(@constCast(self.model_path));
        }
        if (self.template_owned) {
            if (self.template) |t| self.allocator.free(@constCast(t));
        }
        if (self.system_prompt_owned) {
            if (self.system_prompt) |sp| self.allocator.free(@constCast(sp));
        }
        if (self.grammar_file_owned) {
            if (self.grammar_file) |gf| self.allocator.free(@constCast(gf));
        }
    }
};

/// User configuration settings (loaded from config.json)
pub const UserConfig = struct {
    allocator: std.mem.Allocator,

    // Model defaults
    gpu_layers: i32 = 0,
    max_tokens: usize = 2048,
    context_size: ?u32 = null,

    // Sampling parameters
    temperature: f32 = 0.7,
    top_p: f32 = 0.9,
    top_k: i32 = 40,
    repeat_penalty: f32 = 1.1,
    seed: u32 = 0,

    // Chat defaults
    system_prompt: []const u8 = "You are a helpful assistant.",
    system_prompt_owned: bool = false,
    template: []const u8 = "auto",
    template_owned: bool = false,
    quiet: bool = false,

    // Model aliases (name -> path mapping)
    aliases: std.StringHashMap([]const u8),

    // Default model path (optional)
    default_model: ?[]const u8 = null,
    default_model_owned: bool = false,

    // Per-model configurations (model_path -> ModelConfig)
    model_configs: std.StringHashMap(ModelConfig),

    const Self = @This();

    /// Initialize with default values
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .aliases = std.StringHashMap([]const u8).init(allocator),
            .model_configs = std.StringHashMap(ModelConfig).init(allocator),
        };
    }

    /// Load configuration from file
    pub fn load(allocator: std.mem.Allocator, config_path: []const u8) !Self {
        var self = Self.init(allocator);
        errdefer self.deinit();

        const file = std.fs.cwd().openFile(config_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                // No config file is fine, use defaults
                return self;
            }
            return err;
        };
        defer file.close();

        const content = file.readToEndAlloc(allocator, 1024 * 1024) catch {
            // If we can't read, just use defaults
            return self;
        };
        defer allocator.free(content);

        // Parse JSON
        self.parseJson(content) catch {
            // If parsing fails, use defaults
            return self;
        };

        return self;
    }

    /// Get configuration for a specific model, merging with global defaults
    pub fn getModelConfig(self: *const Self, model_path: []const u8) ModelConfig {
        // Start with global defaults
        var cfg = ModelConfig{
            .allocator = self.allocator,
            .model_path = model_path,
            .gpu_layers = self.gpu_layers,
            .context_size = self.context_size,
            .max_tokens = self.max_tokens,
            .temperature = self.temperature,
            .top_p = self.top_p,
            .top_k = self.top_k,
            .repeat_penalty = self.repeat_penalty,
        };

        // Override with model-specific settings if available
        if (self.model_configs.get(model_path)) |model_cfg| {
            if (model_cfg.gpu_layers) |v| cfg.gpu_layers = v;
            if (model_cfg.context_size) |v| cfg.context_size = v;
            if (model_cfg.max_tokens) |v| cfg.max_tokens = v;
            if (model_cfg.temperature) |v| cfg.temperature = v;
            if (model_cfg.top_p) |v| cfg.top_p = v;
            if (model_cfg.top_k) |v| cfg.top_k = v;
            if (model_cfg.repeat_penalty) |v| cfg.repeat_penalty = v;
            if (model_cfg.template) |v| cfg.template = v;
            if (model_cfg.system_prompt) |v| cfg.system_prompt = v;
            if (model_cfg.grammar_file) |v| cfg.grammar_file = v;
        }

        return cfg;
    }

    /// Set a per-model configuration value
    pub fn setModelConfig(self: *Self, model_path: []const u8, key: []const u8, value: []const u8) !void {
        // Get or create model config
        const result = try self.model_configs.getOrPut(model_path);
        if (!result.found_existing) {
            result.value_ptr.* = try ModelConfig.init(self.allocator, model_path);
        }
        var cfg = result.value_ptr;

        // Set the value
        if (std.mem.eql(u8, key, "gpu_layers")) {
            cfg.gpu_layers = std.fmt.parseInt(i32, value, 10) catch null;
        } else if (std.mem.eql(u8, key, "context_size")) {
            cfg.context_size = std.fmt.parseInt(u32, value, 10) catch null;
        } else if (std.mem.eql(u8, key, "max_tokens")) {
            cfg.max_tokens = std.fmt.parseInt(usize, value, 10) catch null;
        } else if (std.mem.eql(u8, key, "temperature")) {
            cfg.temperature = std.fmt.parseFloat(f32, value) catch null;
        } else if (std.mem.eql(u8, key, "top_p")) {
            cfg.top_p = std.fmt.parseFloat(f32, value) catch null;
        } else if (std.mem.eql(u8, key, "top_k")) {
            cfg.top_k = std.fmt.parseInt(i32, value, 10) catch null;
        } else if (std.mem.eql(u8, key, "repeat_penalty")) {
            cfg.repeat_penalty = std.fmt.parseFloat(f32, value) catch null;
        } else if (std.mem.eql(u8, key, "template")) {
            if (cfg.template_owned) {
                if (cfg.template) |t| self.allocator.free(@constCast(t));
            }
            cfg.template = try self.allocator.dupe(u8, value);
            cfg.template_owned = true;
        } else if (std.mem.eql(u8, key, "system_prompt")) {
            if (cfg.system_prompt_owned) {
                if (cfg.system_prompt) |sp| self.allocator.free(@constCast(sp));
            }
            cfg.system_prompt = try self.allocator.dupe(u8, value);
            cfg.system_prompt_owned = true;
        } else if (std.mem.eql(u8, key, "grammar_file")) {
            if (cfg.grammar_file_owned) {
                if (cfg.grammar_file) |gf| self.allocator.free(@constCast(gf));
            }
            cfg.grammar_file = try self.allocator.dupe(u8, value);
            cfg.grammar_file_owned = true;
        }
    }

    /// Parse JSON configuration content
    fn parseJson(self: *Self, content: []const u8) !void {
        // Parse gpu_layers
        if (findJsonNumber(content, "\"gpu_layers\"")) |value| {
            self.gpu_layers = @intFromFloat(value);
        }

        // Parse max_tokens
        if (findJsonNumber(content, "\"max_tokens\"")) |value| {
            self.max_tokens = @intFromFloat(value);
        }

        // Parse context_size
        if (findJsonNumber(content, "\"context_size\"")) |value| {
            self.context_size = @intFromFloat(value);
        }

        // Parse temperature
        if (findJsonNumber(content, "\"temperature\"")) |value| {
            self.temperature = @floatCast(value);
        }

        // Parse top_p
        if (findJsonNumber(content, "\"top_p\"")) |value| {
            self.top_p = @floatCast(value);
        }

        // Parse top_k
        if (findJsonNumber(content, "\"top_k\"")) |value| {
            self.top_k = @intFromFloat(value);
        }

        // Parse repeat_penalty
        if (findJsonNumber(content, "\"repeat_penalty\"")) |value| {
            self.repeat_penalty = @floatCast(value);
        }

        // Parse seed
        if (findJsonNumber(content, "\"seed\"")) |value| {
            self.seed = @intFromFloat(value);
        }

        // Parse quiet
        if (findJsonBool(content, "\"quiet\"")) |value| {
            self.quiet = value;
        }

        // Parse system_prompt
        if (findJsonStringValue(content, "\"system_prompt\"")) |value| {
            self.system_prompt = try self.allocator.dupe(u8, value);
            self.system_prompt_owned = true;
        }

        // Parse template
        if (findJsonStringValue(content, "\"template\"")) |value| {
            self.template = try self.allocator.dupe(u8, value);
            self.template_owned = true;
        }

        // Parse default_model
        if (findJsonStringValue(content, "\"default_model\"")) |value| {
            if (value.len > 0) {
                self.default_model = try self.allocator.dupe(u8, value);
                self.default_model_owned = true;
            }
        }

        // Parse aliases object
        if (std.mem.indexOf(u8, content, "\"aliases\"")) |aliases_start| {
            var search_pos = aliases_start;
            // Find opening brace
            while (search_pos < content.len and content[search_pos] != '{') : (search_pos += 1) {}
            if (search_pos < content.len) {
                search_pos += 1;
                // Parse key-value pairs until closing brace
                while (search_pos < content.len) {
                    // Skip whitespace
                    while (search_pos < content.len and (content[search_pos] == ' ' or content[search_pos] == '\n' or content[search_pos] == '\t' or content[search_pos] == '\r' or content[search_pos] == ',')) : (search_pos += 1) {}
                    if (search_pos >= content.len or content[search_pos] == '}') break;

                    // Parse key
                    if (content[search_pos] == '"') {
                        search_pos += 1;
                        const key_start = search_pos;
                        while (search_pos < content.len and content[search_pos] != '"') : (search_pos += 1) {}
                        const key = content[key_start..search_pos];
                        search_pos += 1;

                        // Skip to colon
                        while (search_pos < content.len and content[search_pos] != ':') : (search_pos += 1) {}
                        search_pos += 1;

                        // Skip whitespace
                        while (search_pos < content.len and (content[search_pos] == ' ' or content[search_pos] == '\n' or content[search_pos] == '\t')) : (search_pos += 1) {}

                        // Parse value
                        if (search_pos < content.len and content[search_pos] == '"') {
                            search_pos += 1;
                            const val_start = search_pos;
                            while (search_pos < content.len and content[search_pos] != '"') : (search_pos += 1) {}
                            const val = content[val_start..search_pos];
                            search_pos += 1;

                            // Store alias
                            const key_copy = try self.allocator.dupe(u8, key);
                            const val_copy = try self.allocator.dupe(u8, val);
                            try self.aliases.put(key_copy, val_copy);
                        }
                    }
                }
            }
        }

        // Parse model_configs object (per-model settings)
        if (std.mem.indexOf(u8, content, "\"model_configs\"")) |mc_start| {
            try self.parseModelConfigs(content[mc_start..]);
        }
    }

    /// Parse per-model configuration section
    fn parseModelConfigs(self: *Self, content: []const u8) !void {
        var search_pos: usize = 0;

        // Find opening brace for model_configs
        while (search_pos < content.len and content[search_pos] != '{') : (search_pos += 1) {}
        if (search_pos >= content.len) return;
        search_pos += 1;

        var brace_depth: usize = 1;
        var current_model: ?[]const u8 = null;

        while (search_pos < content.len and brace_depth > 0) {
            // Skip whitespace
            while (search_pos < content.len and (content[search_pos] == ' ' or content[search_pos] == '\n' or content[search_pos] == '\t' or content[search_pos] == '\r' or content[search_pos] == ',')) : (search_pos += 1) {}
            if (search_pos >= content.len) break;

            if (content[search_pos] == '}') {
                brace_depth -= 1;
                search_pos += 1;
                if (brace_depth == 0) break;
                current_model = null;
                continue;
            }

            if (content[search_pos] == '{') {
                brace_depth += 1;
                search_pos += 1;
                continue;
            }

            // Parse model key
            if (content[search_pos] == '"' and brace_depth == 1) {
                search_pos += 1;
                const key_start = search_pos;
                while (search_pos < content.len and content[search_pos] != '"') : (search_pos += 1) {}
                current_model = content[key_start..search_pos];
                search_pos += 1;
                continue;
            }

            // Parse setting within model config
            if (content[search_pos] == '"' and brace_depth == 2 and current_model != null) {
                search_pos += 1;
                const setting_start = search_pos;
                while (search_pos < content.len and content[search_pos] != '"') : (search_pos += 1) {}
                const setting_name = content[setting_start..search_pos];
                search_pos += 1;

                // Skip to colon and value
                while (search_pos < content.len and content[search_pos] != ':') : (search_pos += 1) {}
                search_pos += 1;
                while (search_pos < content.len and (content[search_pos] == ' ' or content[search_pos] == '\t')) : (search_pos += 1) {}

                // Get value
                if (search_pos < content.len) {
                    if (content[search_pos] == '"') {
                        // String value
                        search_pos += 1;
                        const val_start = search_pos;
                        while (search_pos < content.len and content[search_pos] != '"') : (search_pos += 1) {}
                        const value = content[val_start..search_pos];
                        search_pos += 1;
                        try self.setModelConfig(current_model.?, setting_name, value);
                    } else {
                        // Numeric value
                        const val_start = search_pos;
                        while (search_pos < content.len and (content[search_pos] >= '0' and content[search_pos] <= '9' or content[search_pos] == '.' or content[search_pos] == '-')) : (search_pos += 1) {}
                        const value = content[val_start..search_pos];
                        try self.setModelConfig(current_model.?, setting_name, value);
                    }
                }
                continue;
            }

            search_pos += 1;
        }
    }

    pub fn deinit(self: *Self) void {
        if (self.system_prompt_owned) {
            self.allocator.free(@constCast(self.system_prompt));
        }
        if (self.template_owned) {
            self.allocator.free(@constCast(self.template));
        }
        if (self.default_model_owned) {
            if (self.default_model) |dm| {
                self.allocator.free(@constCast(dm));
            }
        }

        // Free aliases
        var it = self.aliases.iterator();
        while (it.next()) |entry| {
            self.allocator.free(@constCast(entry.key_ptr.*));
            self.allocator.free(@constCast(entry.value_ptr.*));
        }
        self.aliases.deinit();

        // Free model configs
        var mc_it = self.model_configs.iterator();
        while (mc_it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.model_configs.deinit();
    }

    /// Get model path for an alias, or return the input if not found
    pub fn resolveModelAlias(self: *const Self, name: []const u8) []const u8 {
        return self.aliases.get(name) orelse name;
    }

    /// Save configuration to file
    pub fn save(self: *const Self, config_path: []const u8) !void {
        var file = try std.fs.cwd().createFile(config_path, .{});
        defer file.close();

        // Build JSON content
        var content: std.ArrayList(u8) = .empty;
        defer content.deinit(self.allocator);

        try content.appendSlice(self.allocator, "{\n");
        try content.appendSlice(self.allocator, "  \"defaults\": {\n");

        // Write numeric values
        var buf: [64]u8 = undefined;
        try content.appendSlice(self.allocator, "    \"gpu_layers\": ");
        try content.appendSlice(self.allocator, std.fmt.bufPrint(&buf, "{d}", .{self.gpu_layers}) catch "0");
        try content.appendSlice(self.allocator, ",\n");

        try content.appendSlice(self.allocator, "    \"max_tokens\": ");
        try content.appendSlice(self.allocator, std.fmt.bufPrint(&buf, "{d}", .{self.max_tokens}) catch "2048");
        try content.appendSlice(self.allocator, ",\n");

        try content.appendSlice(self.allocator, "    \"temperature\": ");
        try content.appendSlice(self.allocator, std.fmt.bufPrint(&buf, "{d:.2}", .{self.temperature}) catch "0.7");
        try content.appendSlice(self.allocator, ",\n");

        try content.appendSlice(self.allocator, "    \"top_p\": ");
        try content.appendSlice(self.allocator, std.fmt.bufPrint(&buf, "{d:.2}", .{self.top_p}) catch "0.9");
        try content.appendSlice(self.allocator, ",\n");

        try content.appendSlice(self.allocator, "    \"top_k\": ");
        try content.appendSlice(self.allocator, std.fmt.bufPrint(&buf, "{d}", .{self.top_k}) catch "40");
        try content.appendSlice(self.allocator, ",\n");

        try content.appendSlice(self.allocator, "    \"repeat_penalty\": ");
        try content.appendSlice(self.allocator, std.fmt.bufPrint(&buf, "{d:.2}", .{self.repeat_penalty}) catch "1.1");
        try content.appendSlice(self.allocator, "\n");

        try content.appendSlice(self.allocator, "  },\n");

        try content.appendSlice(self.allocator, "  \"chat\": {\n");
        try content.appendSlice(self.allocator, "    \"system_prompt\": \"");
        try appendJsonEscaped(&content, self.allocator, self.system_prompt);
        try content.appendSlice(self.allocator, "\",\n");
        try content.appendSlice(self.allocator, "    \"template\": \"");
        try content.appendSlice(self.allocator, self.template);
        try content.appendSlice(self.allocator, "\",\n");
        try content.appendSlice(self.allocator, "    \"quiet\": ");
        try content.appendSlice(self.allocator, if (self.quiet) "true" else "false");
        try content.appendSlice(self.allocator, "\n");
        try content.appendSlice(self.allocator, "  },\n");

        try content.appendSlice(self.allocator, "  \"models\": {\n");
        if (self.default_model) |dm| {
            try content.appendSlice(self.allocator, "    \"default\": \"");
            try content.appendSlice(self.allocator, dm);
            try content.appendSlice(self.allocator, "\",\n");
        } else {
            try content.appendSlice(self.allocator, "    \"default\": null,\n");
        }
        try content.appendSlice(self.allocator, "    \"aliases\": {\n");

        var alias_it = self.aliases.iterator();
        var first = true;
        while (alias_it.next()) |entry| {
            if (!first) {
                try content.appendSlice(self.allocator, ",\n");
            }
            first = false;
            try content.appendSlice(self.allocator, "      \"");
            try content.appendSlice(self.allocator, entry.key_ptr.*);
            try content.appendSlice(self.allocator, "\": \"");
            try content.appendSlice(self.allocator, entry.value_ptr.*);
            try content.appendSlice(self.allocator, "\"");
        }
        if (!first) {
            try content.appendSlice(self.allocator, "\n");
        }

        try content.appendSlice(self.allocator, "    }\n");
        try content.appendSlice(self.allocator, "  },\n");

        // Write per-model configs
        try content.appendSlice(self.allocator, "  \"model_configs\": {\n");

        var mc_it = self.model_configs.iterator();
        var first_model = true;
        while (mc_it.next()) |entry| {
            if (!first_model) {
                try content.appendSlice(self.allocator, ",\n");
            }
            first_model = false;

            try content.appendSlice(self.allocator, "    \"");
            try content.appendSlice(self.allocator, entry.key_ptr.*);
            try content.appendSlice(self.allocator, "\": {\n");

            const cfg = entry.value_ptr;
            var has_prev = false;

            if (cfg.gpu_layers) |v| {
                try content.appendSlice(self.allocator, "      \"gpu_layers\": ");
                try content.appendSlice(self.allocator, std.fmt.bufPrint(&buf, "{d}", .{v}) catch "0");
                has_prev = true;
            }
            if (cfg.context_size) |v| {
                if (has_prev) try content.appendSlice(self.allocator, ",\n") else has_prev = true;
                try content.appendSlice(self.allocator, "      \"context_size\": ");
                try content.appendSlice(self.allocator, std.fmt.bufPrint(&buf, "{d}", .{v}) catch "2048");
            }
            if (cfg.template) |v| {
                if (has_prev) try content.appendSlice(self.allocator, ",\n") else has_prev = true;
                try content.appendSlice(self.allocator, "      \"template\": \"");
                try content.appendSlice(self.allocator, v);
                try content.appendSlice(self.allocator, "\"");
            }
            if (cfg.grammar_file) |v| {
                if (has_prev) try content.appendSlice(self.allocator, ",\n") else has_prev = true;
                try content.appendSlice(self.allocator, "      \"grammar_file\": \"");
                try content.appendSlice(self.allocator, v);
                try content.appendSlice(self.allocator, "\"");
            }

            if (has_prev) try content.appendSlice(self.allocator, "\n");
            try content.appendSlice(self.allocator, "    }");
        }
        if (!first_model) {
            try content.appendSlice(self.allocator, "\n");
        }

        try content.appendSlice(self.allocator, "  }\n");
        try content.appendSlice(self.allocator, "}\n");

        try file.writeAll(content.items);
    }
};

/// Helper: Find a JSON number value by key
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

/// Helper: Find a JSON boolean value by key
fn findJsonBool(content: []const u8, key: []const u8) ?bool {
    if (std.mem.indexOf(u8, content, key)) |key_start| {
        var search_pos = key_start + key.len;
        // Skip to colon
        while (search_pos < content.len and content[search_pos] != ':') : (search_pos += 1) {}
        search_pos += 1;
        // Skip whitespace
        while (search_pos < content.len and (content[search_pos] == ' ' or content[search_pos] == '\n' or content[search_pos] == '\t')) : (search_pos += 1) {}
        if (search_pos + 4 <= content.len and std.mem.eql(u8, content[search_pos .. search_pos + 4], "true")) {
            return true;
        }
        if (search_pos + 5 <= content.len and std.mem.eql(u8, content[search_pos .. search_pos + 5], "false")) {
            return false;
        }
    }
    return null;
}

/// Helper: Find a JSON string value by key
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

/// Helper: Append JSON-escaped string
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

/// Configuration for igllama paths and cache management
pub const Config = struct {
    allocator: std.mem.Allocator,
    /// Base directory for igllama data (models, cache, etc.)
    home_dir: []const u8,
    /// Directory where downloaded models are cached
    cache_dir: []const u8,

    const Self = @This();

    /// Initialize config, checking IGLLAMA_HOME env var first, then falling back to defaults
    pub fn init(allocator: std.mem.Allocator) !Self {
        // Check for IGLLAMA_HOME environment variable
        const home_dir = std.process.getEnvVarOwned(allocator, "IGLLAMA_HOME") catch |err| blk: {
            if (err == error.EnvironmentVariableNotFound) {
                // Fall back to platform-specific default
                break :blk try getDefaultHomeDir(allocator);
            }
            return err;
        };

        // Cache dir is home_dir/hub (compatible with hf-hub-zig default structure)
        const cache_dir = try std.fs.path.join(allocator, &.{ home_dir, "hub" });

        return Self{
            .allocator = allocator,
            .home_dir = home_dir,
            .cache_dir = cache_dir,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.cache_dir);
        self.allocator.free(self.home_dir);
    }

    /// Get the default home directory based on platform
    fn getDefaultHomeDir(allocator: std.mem.Allocator) ![]const u8 {
        if (builtin.os.tag == .windows) {
            // Windows: %USERPROFILE%\.cache\huggingface
            const userprofile = try std.process.getEnvVarOwned(allocator, "USERPROFILE");
            defer allocator.free(userprofile);
            return try std.fs.path.join(allocator, &.{ userprofile, ".cache", "huggingface" });
        } else {
            // Unix: ~/.cache/huggingface (XDG_CACHE_HOME or $HOME/.cache)
            const home = std.process.getEnvVarOwned(allocator, "XDG_CACHE_HOME") catch |err| blk: {
                if (err == error.EnvironmentVariableNotFound) {
                    const user_home = try std.process.getEnvVarOwned(allocator, "HOME");
                    defer allocator.free(user_home);
                    break :blk try std.fs.path.join(allocator, &.{ user_home, ".cache" });
                }
                return err;
            };
            defer allocator.free(home);
            return try std.fs.path.join(allocator, &.{ home, "huggingface" });
        }
    }

    /// Get the path where a specific model repo would be stored
    /// Format: cache_dir/models--{owner}--{repo}
    pub fn getModelPath(self: *const Self, repo_id: []const u8) ![]const u8 {
        // Build models--owner--repo format
        // e.g., "bartowski/Llama-3-8B-Instruct-GGUF" -> "models--bartowski--Llama-3-8B-Instruct-GGUF"
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(self.allocator);

        try result.appendSlice(self.allocator, "models--");
        for (repo_id) |c| {
            if (c == '/') {
                try result.appendSlice(self.allocator, "--");
            } else {
                try result.append(self.allocator, c);
            }
        }

        const dir_name = try result.toOwnedSlice(self.allocator);
        defer self.allocator.free(dir_name);

        return try std.fs.path.join(self.allocator, &.{ self.cache_dir, dir_name });
    }

    /// Get the path to the server PID file
    pub fn getServerPidPath(self: *const Self) ![]const u8 {
        return try std.fs.path.join(self.allocator, &.{ self.home_dir, "server.pid" });
    }

    /// Get the path to the server log file
    pub fn getServerLogPath(self: *const Self) ![]const u8 {
        return try std.fs.path.join(self.allocator, &.{ self.home_dir, "server.log" });
    }

    /// Get the path to the server config file
    pub fn getServerConfigPath(self: *const Self) ![]const u8 {
        return try std.fs.path.join(self.allocator, &.{ self.home_dir, "server.json" });
    }

    /// Get the path to the user config file
    pub fn getUserConfigPath(self: *const Self) ![]const u8 {
        return try std.fs.path.join(self.allocator, &.{ self.home_dir, "config.json" });
    }

    /// Load user configuration from the default config file
    pub fn loadUserConfig(self: *const Self) !UserConfig {
        const config_path = try self.getUserConfigPath();
        defer self.allocator.free(config_path);
        return try UserConfig.load(self.allocator, config_path);
    }
};

/// Version information
pub const version = "0.2.0";
pub const app_name = "igllama";
pub const app_description = "A Zig-based Ollama alternative for GGUF model management";

/// Default server settings
pub const default_server_host = "127.0.0.1";
pub const default_server_port: u16 = 8080;

// ============================================================================
// Tests
// ============================================================================

test "Config.getModelPath transforms repo_id correctly" {
    const allocator = std.testing.allocator;

    // Create a mock config for testing
    const home_dir = try allocator.dupe(u8, "/tmp/test-igllama");
    const cache_dir = try std.fs.path.join(allocator, &.{ home_dir, "hub" });

    var cfg = Config{
        .allocator = allocator,
        .home_dir = home_dir,
        .cache_dir = cache_dir,
    };
    defer cfg.deinit();

    const model_path = try cfg.getModelPath("TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF");
    defer allocator.free(model_path);

    // Verify the path contains the transformed repo_id
    try std.testing.expect(std.mem.indexOf(u8, model_path, "models--TheBloke--TinyLlama-1.1B-Chat-v1.0-GGUF") != null);
}

test "Config.getServerPidPath returns valid path" {
    const allocator = std.testing.allocator;

    const home_dir = try allocator.dupe(u8, "/tmp/test-igllama");
    const cache_dir = try std.fs.path.join(allocator, &.{ home_dir, "hub" });

    var cfg = Config{
        .allocator = allocator,
        .home_dir = home_dir,
        .cache_dir = cache_dir,
    };
    defer cfg.deinit();

    const pid_path = try cfg.getServerPidPath();
    defer allocator.free(pid_path);

    try std.testing.expect(std.mem.endsWith(u8, pid_path, "server.pid"));
}

test "version and app_name constants are set" {
    try std.testing.expectEqualStrings("0.2.0", version);
    try std.testing.expectEqualStrings("igllama", app_name);
    try std.testing.expect(default_server_port == 8080);
}
