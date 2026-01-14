const std = @import("std");

/// Unified error types for igllama with detailed context
pub const IgLlamaError = error{
    // File/Model errors
    FileNotFound,
    PermissionDenied,
    InvalidGgufFile,
    CorruptedModel,
    UnsupportedModelVersion,

    // Loading errors
    FailedToLoadModel,
    MissingVocabulary,
    ContextCreationFailed,
    OutOfMemory,

    // Runtime errors
    GenerationFailed,
    KvCacheFull,
    TokenizationFailed,
    InvalidArguments,

    // Server errors
    ServerAlreadyRunning,
    ServerNotRunning,
    ServerStartFailed,
    PortInUse,

    // Network errors
    DownloadFailed,
    ConnectionFailed,
    RateLimited,
    AuthenticationRequired,

    // Grammar errors
    InvalidGrammar,
    GrammarParseFailed,
};

/// Error context with helpful suggestions
pub const ErrorContext = struct {
    code: IgLlamaError,
    message: []const u8,
    suggestion: []const u8,
    details: ?[]const u8 = null,

    pub fn format(self: *const ErrorContext, buf: []u8) []const u8 {
        var pos: usize = 0;

        // Error message
        const msg_start = "Error: ";
        if (pos + msg_start.len < buf.len) {
            @memcpy(buf[pos..][0..msg_start.len], msg_start);
            pos += msg_start.len;
        }
        if (pos + self.message.len < buf.len) {
            @memcpy(buf[pos..][0..self.message.len], self.message);
            pos += self.message.len;
        }
        if (pos + 1 < buf.len) {
            buf[pos] = '\n';
            pos += 1;
        }

        // Details if present
        if (self.details) |details| {
            const det_prefix = "  Details: ";
            if (pos + det_prefix.len < buf.len) {
                @memcpy(buf[pos..][0..det_prefix.len], det_prefix);
                pos += det_prefix.len;
            }
            const det_len = @min(details.len, buf.len - pos - 1);
            @memcpy(buf[pos..][0..det_len], details[0..det_len]);
            pos += det_len;
            if (pos + 1 < buf.len) {
                buf[pos] = '\n';
                pos += 1;
            }
        }

        // Suggestion
        if (self.suggestion.len > 0) {
            const sug_prefix = "\nSuggestion: ";
            if (pos + sug_prefix.len < buf.len) {
                @memcpy(buf[pos..][0..sug_prefix.len], sug_prefix);
                pos += sug_prefix.len;
            }
            const sug_len = @min(self.suggestion.len, buf.len - pos);
            @memcpy(buf[pos..][0..sug_len], self.suggestion[0..sug_len]);
            pos += sug_len;
        }

        return buf[0..pos];
    }
};

/// Get context for common errors
pub fn getErrorContext(err: anyerror) ErrorContext {
    return switch (err) {
        error.FileNotFound => .{
            .code = IgLlamaError.FileNotFound,
            .message = "Model file not found",
            .suggestion = "Check the file path. Use 'igllama list' to see downloaded models, or 'igllama pull <repo_id>' to download.",
        },
        error.PermissionDenied, error.AccessDenied => .{
            .code = IgLlamaError.PermissionDenied,
            .message = "Permission denied accessing the file",
            .suggestion = "Check file permissions. On Unix, try 'chmod +r <file>'. On Windows, check Security properties.",
        },
        error.InvalidGgufFile => .{
            .code = IgLlamaError.InvalidGgufFile,
            .message = "Invalid or corrupted GGUF model file",
            .suggestion = "Re-download the model with 'igllama pull'. If the issue persists, try a different quantization variant.",
        },
        error.FailedToLoadModel => .{
            .code = IgLlamaError.FailedToLoadModel,
            .message = "Failed to load the model",
            .suggestion = "This may be a memory issue. Try:\n  1. Closing other applications\n  2. Using a smaller quantization (Q4_K_S instead of Q8)\n  3. Reducing --gpu-layers if using GPU",
        },
        error.MissingVocabulary => .{
            .code = IgLlamaError.MissingVocabulary,
            .message = "Model is missing vocabulary/tokenizer data",
            .suggestion = "The model file may be incomplete or a base model without tokenizer. Use a model with built-in vocabulary.",
        },
        error.ContextCreationFailed => .{
            .code = IgLlamaError.ContextCreationFailed,
            .message = "Failed to create inference context",
            .suggestion = "Try reducing context size with --context-size (e.g., --context-size 2048). Also try fewer GPU layers.",
        },
        error.OutOfMemory => .{
            .code = IgLlamaError.OutOfMemory,
            .message = "Out of memory",
            .suggestion = "The model requires more RAM than available. Options:\n  1. Use a smaller quantization (Q4_K_S, Q3_K_M)\n  2. Reduce context size with --context-size\n  3. Close other applications\n  4. Use fewer GPU layers",
        },
        error.ServerAlreadyRunning => .{
            .code = IgLlamaError.ServerAlreadyRunning,
            .message = "Server is already running",
            .suggestion = "Stop the existing server with 'igllama serve stop' before starting a new one.",
        },
        error.InvalidArguments => .{
            .code = IgLlamaError.InvalidArguments,
            .message = "Invalid command-line arguments",
            .suggestion = "Use 'igllama help' to see available commands and options.",
        },
        error.InvalidGrammar => .{
            .code = IgLlamaError.InvalidGrammar,
            .message = "Invalid grammar specification",
            .suggestion = "Check your GBNF grammar syntax. See llama.cpp grammars documentation for examples.",
        },
        error.DownloadFailed => .{
            .code = IgLlamaError.DownloadFailed,
            .message = "Failed to download model",
            .suggestion = "Check your internet connection and try again. For large models, the download may have timed out.",
        },
        error.AuthenticationRequired => .{
            .code = IgLlamaError.AuthenticationRequired,
            .message = "Authentication required to access this model",
            .suggestion = "Set HF_TOKEN environment variable with your HuggingFace token. Get one at https://huggingface.co/settings/tokens",
        },
        else => .{
            .code = IgLlamaError.GenerationFailed,
            .message = "An unexpected error occurred",
            .suggestion = "Try running with more verbose output or check the model compatibility.",
        },
    };
}

/// Print a formatted error message
pub fn printError(stderr: anytype, err: anyerror, extra_context: ?[]const u8) void {
    const ctx = getErrorContext(err);

    stderr.print("\n{s} Error: {s}\n", .{ errorIcon(), ctx.message }) catch return;

    if (extra_context) |details| {
        stderr.print("  {s}\n", .{details}) catch return;
    }

    if (ctx.suggestion.len > 0) {
        stderr.print("\n{s} Suggestion: {s}\n", .{ hintIcon(), ctx.suggestion }) catch return;
    }

    stderr.flush() catch {};
}

/// Print error with technical details
pub fn printErrorWithDetails(stderr: anytype, err: anyerror, details: []const u8) void {
    const ctx = getErrorContext(err);

    stderr.print("\n{s} Error: {s}\n", .{ errorIcon(), ctx.message }) catch return;
    stderr.print("  Technical details: {s}\n", .{details}) catch return;
    stderr.print("  Error code: {s}\n", .{@errorName(err)}) catch return;

    if (ctx.suggestion.len > 0) {
        stderr.print("\n{s} Suggestion: {s}\n", .{ hintIcon(), ctx.suggestion }) catch return;
    }

    stderr.flush() catch {};
}

/// Icon helpers (can be disabled for non-UTF8 terminals)
fn errorIcon() []const u8 {
    return "[!]";
}

fn hintIcon() []const u8 {
    return "[i]";
}

/// Format memory requirement error
pub fn formatMemoryError(stderr: anytype, required_mb: u64, available_mb: u64) void {
    stderr.print("\n{s} Error: Insufficient memory\n", .{errorIcon()}) catch return;
    stderr.print("  Required:  ~{d} MB\n", .{required_mb}) catch return;
    stderr.print("  Available: ~{d} MB\n", .{available_mb}) catch return;
    stderr.print("\n{s} Try:\n", .{hintIcon()}) catch return;
    stderr.print("  1. Use a smaller quantization (Q4_K_S, IQ4_XS)\n", .{}) catch return;
    stderr.print("  2. Reduce context size: --context-size 2048\n", .{}) catch return;
    stderr.print("  3. Offload fewer layers to GPU: --gpu-layers 0\n", .{}) catch return;
    stderr.flush() catch {};
}

// Tests
test "getErrorContext returns valid context" {
    const ctx = getErrorContext(error.OutOfMemory);
    try std.testing.expect(ctx.message.len > 0);
    try std.testing.expect(ctx.suggestion.len > 0);
}
