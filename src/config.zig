const std = @import("std");
const builtin = @import("builtin");

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
};

/// Version information
pub const version = "0.1.0";
pub const app_name = "igllama";
pub const app_description = "A Zig-based Ollama alternative for GGUF model management";
