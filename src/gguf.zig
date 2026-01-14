const std = @import("std");
const zenmap = @import("zenmap");

/// GGUF magic number (bytes: "GGUF")
pub const GGUF_MAGIC: u32 = 0x46554747; // "GGUF" in little-endian

/// Minimum valid GGUF file size (header only)
pub const MIN_GGUF_SIZE: usize = 24; // magic(4) + version(4) + tensor_count(8) + metadata_count(8)

/// Maximum supported GGUF version
pub const MAX_SUPPORTED_VERSION: u32 = 3;

/// GGUF validation error types
pub const ValidationError = error{
    FileNotFound,
    PermissionDenied,
    FileTooSmall,
    InvalidMagic,
    UnsupportedVersion,
    CorruptedFile,
    ReadError,
};

/// Quantization type information
pub const QuantizationType = enum {
    F32,
    F16,
    Q4_0,
    Q4_1,
    Q5_0,
    Q5_1,
    Q8_0,
    Q8_1,
    Q2_K,
    Q3_K_S,
    Q3_K_M,
    Q3_K_L,
    Q4_K_S,
    Q4_K_M,
    Q5_K_S,
    Q5_K_M,
    Q6_K,
    Q8_K,
    IQ2_XXS,
    IQ2_XS,
    IQ3_XXS,
    IQ1_S,
    IQ4_NL,
    IQ3_S,
    IQ2_S,
    IQ4_XS,
    IQ1_M,
    BF16,
    Unknown,

    /// Bits per weight for memory estimation
    pub fn bitsPerWeight(self: QuantizationType) f32 {
        return switch (self) {
            .F32 => 32.0,
            .F16, .BF16 => 16.0,
            .Q8_0, .Q8_1, .Q8_K => 8.0,
            .Q6_K => 6.5,
            .Q5_0, .Q5_1, .Q5_K_S, .Q5_K_M => 5.5,
            .Q4_0, .Q4_1, .Q4_K_S, .Q4_K_M, .IQ4_NL, .IQ4_XS => 4.5,
            .Q3_K_S, .Q3_K_M, .Q3_K_L, .IQ3_XXS, .IQ3_S => 3.5,
            .Q2_K, .IQ2_XXS, .IQ2_XS, .IQ2_S => 2.5,
            .IQ1_S, .IQ1_M => 1.5,
            .Unknown => 4.5, // Assume Q4 as default
        };
    }

    /// Human-readable description
    pub fn description(self: QuantizationType) []const u8 {
        return switch (self) {
            .F32 => "32-bit float (unquantized)",
            .F16 => "16-bit float",
            .BF16 => "Brain 16-bit float",
            .Q8_0, .Q8_1, .Q8_K => "8-bit quantization",
            .Q6_K => "6-bit quantization",
            .Q5_0, .Q5_1, .Q5_K_S => "5-bit quantization (small)",
            .Q5_K_M => "5-bit quantization (medium)",
            .Q4_0, .Q4_1, .Q4_K_S => "4-bit quantization (small)",
            .Q4_K_M => "4-bit quantization (medium)",
            .Q3_K_S => "3-bit quantization (small)",
            .Q3_K_M => "3-bit quantization (medium)",
            .Q3_K_L => "3-bit quantization (large)",
            .Q2_K => "2-bit quantization",
            .IQ4_NL, .IQ4_XS => "4-bit importance quantization",
            .IQ3_XXS, .IQ3_S => "3-bit importance quantization",
            .IQ2_XXS, .IQ2_XS, .IQ2_S => "2-bit importance quantization",
            .IQ1_S, .IQ1_M => "1-bit importance quantization",
            .Unknown => "Unknown quantization",
        };
    }

    /// Parse from file type integer
    pub fn fromFileType(file_type: u32) QuantizationType {
        return switch (file_type) {
            0 => .F32,
            1 => .F16,
            2 => .Q4_0,
            3 => .Q4_1,
            6 => .Q5_0,
            7 => .Q5_1,
            8 => .Q8_0,
            10 => .Q2_K,
            11 => .Q3_K_S,
            12 => .Q3_K_M,
            13 => .Q3_K_L,
            14 => .Q4_K_S,
            15 => .Q4_K_M,
            16 => .Q5_K_S,
            17 => .Q5_K_M,
            18 => .Q6_K,
            19 => .IQ2_XXS,
            20 => .IQ2_XS,
            21 => .IQ3_XXS,
            22 => .IQ1_S,
            23 => .IQ4_NL,
            24 => .IQ3_S,
            25 => .IQ2_S,
            26 => .IQ4_XS,
            27 => .IQ1_M,
            28 => .BF16,
            else => .Unknown,
        };
    }
};

/// Model architecture information
pub const ModelArchitecture = enum {
    llama,
    falcon,
    gpt2,
    gptj,
    gptneox,
    mpt,
    baichuan,
    starcoder,
    refact,
    bert,
    bloom,
    stablelm,
    qwen,
    qwen2,
    phi2,
    phi3,
    plamo,
    codeshell,
    orion,
    internlm2,
    minicpm,
    gemma,
    gemma2,
    starcoder2,
    mamba,
    xverse,
    command_r,
    dbrx,
    olmo,
    arctic,
    deepseek,
    deepseek2,
    chatglm,
    bitnet,
    t5,
    jais,
    nemotron,
    exaone,
    rwkv6,
    unknown,

    pub fn fromString(s: []const u8) ModelArchitecture {
        // Convert to lowercase for matching
        var lower_buf: [64]u8 = undefined;
        const s_len = @min(s.len, lower_buf.len);
        for (s[0..s_len], 0..) |c, i| {
            lower_buf[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
        }
        const lower = lower_buf[0..s_len];

        if (std.mem.eql(u8, lower, "llama")) return .llama;
        if (std.mem.eql(u8, lower, "falcon")) return .falcon;
        if (std.mem.eql(u8, lower, "gpt2")) return .gpt2;
        if (std.mem.eql(u8, lower, "gptj")) return .gptj;
        if (std.mem.eql(u8, lower, "gpt_neox") or std.mem.eql(u8, lower, "gptneox")) return .gptneox;
        if (std.mem.eql(u8, lower, "mpt")) return .mpt;
        if (std.mem.eql(u8, lower, "baichuan")) return .baichuan;
        if (std.mem.eql(u8, lower, "starcoder")) return .starcoder;
        if (std.mem.eql(u8, lower, "qwen")) return .qwen;
        if (std.mem.eql(u8, lower, "qwen2")) return .qwen2;
        if (std.mem.eql(u8, lower, "phi2") or std.mem.eql(u8, lower, "phi-2")) return .phi2;
        if (std.mem.eql(u8, lower, "phi3") or std.mem.eql(u8, lower, "phi-3")) return .phi3;
        if (std.mem.eql(u8, lower, "gemma")) return .gemma;
        if (std.mem.eql(u8, lower, "gemma2")) return .gemma2;
        if (std.mem.eql(u8, lower, "mamba")) return .mamba;
        if (std.mem.eql(u8, lower, "command-r") or std.mem.eql(u8, lower, "command_r")) return .command_r;
        if (std.mem.eql(u8, lower, "deepseek")) return .deepseek;
        if (std.mem.eql(u8, lower, "deepseek2")) return .deepseek2;

        return .unknown;
    }

    pub fn toString(self: ModelArchitecture) []const u8 {
        return switch (self) {
            .llama => "LLaMA",
            .falcon => "Falcon",
            .gpt2 => "GPT-2",
            .gptj => "GPT-J",
            .gptneox => "GPT-NeoX",
            .mpt => "MPT",
            .baichuan => "Baichuan",
            .starcoder => "StarCoder",
            .refact => "Refact",
            .bert => "BERT",
            .bloom => "BLOOM",
            .stablelm => "StableLM",
            .qwen => "Qwen",
            .qwen2 => "Qwen2",
            .phi2 => "Phi-2",
            .phi3 => "Phi-3",
            .plamo => "PLaMo",
            .codeshell => "CodeShell",
            .orion => "Orion",
            .internlm2 => "InternLM2",
            .minicpm => "MiniCPM",
            .gemma => "Gemma",
            .gemma2 => "Gemma 2",
            .starcoder2 => "StarCoder2",
            .mamba => "Mamba",
            .xverse => "XVerse",
            .command_r => "Command R",
            .dbrx => "DBRX",
            .olmo => "OLMo",
            .arctic => "Arctic",
            .deepseek => "DeepSeek",
            .deepseek2 => "DeepSeek2",
            .chatglm => "ChatGLM",
            .bitnet => "BitNet",
            .t5 => "T5",
            .jais => "Jais",
            .nemotron => "Nemotron",
            .exaone => "ExaOne",
            .rwkv6 => "RWKV-6",
            .unknown => "Unknown",
        };
    }
};

/// Extended model information extracted from GGUF
pub const ModelInfo = struct {
    name: ?[]const u8 = null,
    architecture: ModelArchitecture = .unknown,
    quantization: QuantizationType = .Unknown,
    context_length: ?u32 = null,
    embedding_length: ?u32 = null,
    head_count: ?u32 = null,
    layer_count: ?u32 = null,
    vocab_size: ?u32 = null,
    parameter_count: ?u64 = null,

    /// Estimate memory required to load the model (in bytes)
    pub fn estimateMemory(self: *const ModelInfo, file_size: usize, context_size: u32) u64 {
        // Base: file size (model weights)
        var memory: u64 = file_size;

        // Add KV cache estimate: 2 * n_layer * n_ctx * n_embd * sizeof(float) * 2 (k+v)
        if (self.layer_count) |layers| {
            if (self.embedding_length) |embd| {
                // KV cache: n_layer * n_ctx * n_embd * 2 (k+v) * 4 bytes (fp32 typical)
                // But often uses fp16, so estimate 2-4 bytes per element
                const kv_bytes: u64 = @as(u64, layers) * @as(u64, context_size) * @as(u64, embd) * 2 * 2;
                memory += kv_bytes;
            }
        }

        // Add overhead for logits, embeddings, scratch buffers (~10-20%)
        memory = memory * 12 / 10;

        return memory;
    }
};

/// Result of GGUF validation with extended information
pub const ValidationResult = struct {
    valid: bool,
    version: ?u32 = null,
    tensor_count: ?u64 = null,
    metadata_count: ?u64 = null,
    file_size: usize = 0,
    error_message: ?[]const u8 = null,
    error_code: ?ErrorCode = null,
    model_info: ModelInfo = .{},

    /// Detailed error codes for programmatic handling
    pub const ErrorCode = enum {
        file_not_found,
        permission_denied,
        file_too_small,
        invalid_magic,
        unsupported_version,
        corrupted_header,
        corrupted_metadata,
        corrupted_tensors,
        io_error,
    };

    /// Get suggested actions for fixing the error
    pub fn getSuggestion(self: *const ValidationResult) []const u8 {
        if (self.error_code) |code| {
            return switch (code) {
                .file_not_found => "Check that the file path is correct. Use 'igllama list' to see available models.",
                .permission_denied => "Check file permissions. You may need to run with elevated privileges.",
                .file_too_small => "The file appears incomplete. Try re-downloading with 'igllama pull'.",
                .invalid_magic => "This is not a valid GGUF file. Ensure you're using a GGUF-format model.",
                .unsupported_version => "This GGUF version is not supported. Try a model with GGUF v2 or v3.",
                .corrupted_header => "The file header is corrupted. Try re-downloading the model.",
                .corrupted_metadata => "Metadata appears corrupted. The model may still load but with issues.",
                .corrupted_tensors => "Tensor data appears corrupted. Re-download the model file.",
                .io_error => "An I/O error occurred. Check disk space and file system health.",
            };
        }
        return "";
    }
};

/// Validate a GGUF file before loading
/// Returns detailed information about the file's validity
pub fn validateFile(path: []const u8) ValidationResult {
    // Check if file exists and is accessible
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        const code: ValidationResult.ErrorCode = switch (err) {
            error.FileNotFound => .file_not_found,
            error.AccessDenied => .permission_denied,
            else => .io_error,
        };
        return .{
            .valid = false,
            .error_code = code,
            .error_message = switch (err) {
                error.FileNotFound => "File not found",
                error.AccessDenied => "Permission denied",
                else => "Cannot open file",
            },
        };
    };
    defer file.close();

    // Get file size
    const stat = file.stat() catch {
        return .{
            .valid = false,
            .error_code = .io_error,
            .error_message = "Cannot read file metadata",
        };
    };

    const file_size = stat.size;

    // Check minimum size
    if (file_size < MIN_GGUF_SIZE) {
        return .{
            .valid = false,
            .file_size = file_size,
            .error_code = .file_too_small,
            .error_message = "File too small to be a valid GGUF file",
        };
    }

    // Read the header
    var header_buf: [24]u8 = undefined;
    const bytes_read = file.read(&header_buf) catch {
        return .{
            .valid = false,
            .file_size = file_size,
            .error_code = .io_error,
            .error_message = "Cannot read file header",
        };
    };

    if (bytes_read < 24) {
        return .{
            .valid = false,
            .file_size = file_size,
            .error_code = .corrupted_header,
            .error_message = "Incomplete file header",
        };
    }

    // Check magic number
    const magic = std.mem.readInt(u32, header_buf[0..4], .little);
    if (magic != GGUF_MAGIC) {
        return .{
            .valid = false,
            .file_size = file_size,
            .error_code = .invalid_magic,
            .error_message = "Not a GGUF file (invalid magic number)",
        };
    }

    // Check version
    const version = std.mem.readInt(u32, header_buf[4..8], .little);
    if (version == 0 or version > MAX_SUPPORTED_VERSION) {
        return .{
            .valid = false,
            .version = version,
            .file_size = file_size,
            .error_code = .unsupported_version,
            .error_message = "Unsupported GGUF version",
        };
    }

    // Read tensor and metadata counts
    const tensor_count = std.mem.readInt(u64, header_buf[8..16], .little);
    const metadata_count = std.mem.readInt(u64, header_buf[16..24], .little);

    // Basic sanity checks
    if (tensor_count > 100000) {
        return .{
            .valid = false,
            .version = version,
            .tensor_count = tensor_count,
            .metadata_count = metadata_count,
            .file_size = file_size,
            .error_code = .corrupted_tensors,
            .error_message = "Suspiciously high tensor count (possible corruption)",
        };
    }

    if (metadata_count > 1000000) {
        return .{
            .valid = false,
            .version = version,
            .tensor_count = tensor_count,
            .metadata_count = metadata_count,
            .file_size = file_size,
            .error_code = .corrupted_metadata,
            .error_message = "Suspiciously high metadata count (possible corruption)",
        };
    }

    // File looks valid - try to extract more metadata using zenmap
    var model_info = ModelInfo{};
    extractModelInfo(path, &model_info);

    // File looks valid
    return .{
        .valid = true,
        .version = version,
        .tensor_count = tensor_count,
        .metadata_count = metadata_count,
        .file_size = file_size,
        .model_info = model_info,
    };
}

/// Extract additional model information from GGUF metadata
///
/// NOTE: This is intentionally a no-op. GGUF metadata extraction requires parsing
/// the full metadata section which is complex and duplicates llama.cpp's functionality.
/// Instead, model info should be extracted via llama.cpp's Model API after loading:
///   - model.metaValStr("general.architecture", &buf) for architecture
///   - model.metaValStr("general.name", &buf) for model name
///   - model.nEmbd(), model.nLayer(), etc. for model dimensions
///   - model.vocab().?.nVocab() for vocabulary size
///
/// The validateFile() function provides basic header validation before loading,
/// while detailed metadata is available through the loaded Model instance.
fn extractModelInfo(path: []const u8, info: *ModelInfo) void {
    _ = path;
    _ = info;
    // Model info is extracted via llama.cpp Model API after loading, not from raw GGUF
}

/// Quick check if a file path points to a valid GGUF file
pub fn isValidGguf(path: []const u8) bool {
    return validateFile(path).valid;
}

/// Format file size for human-readable output
pub fn formatFileSize(size: usize, buf: []u8) []const u8 {
    if (size >= 1024 * 1024 * 1024) {
        const gb = @as(f64, @floatFromInt(size)) / (1024.0 * 1024.0 * 1024.0);
        return std.fmt.bufPrint(buf, "{d:.2} GB", .{gb}) catch "? GB";
    } else if (size >= 1024 * 1024) {
        const mb = @as(f64, @floatFromInt(size)) / (1024.0 * 1024.0);
        return std.fmt.bufPrint(buf, "{d:.2} MB", .{mb}) catch "? MB";
    } else if (size >= 1024) {
        const kb = @as(f64, @floatFromInt(size)) / 1024.0;
        return std.fmt.bufPrint(buf, "{d:.2} KB", .{kb}) catch "? KB";
    } else {
        return std.fmt.bufPrint(buf, "{d} bytes", .{size}) catch "? bytes";
    }
}

/// Format memory size for human-readable output (same as formatFileSize but semantic name)
pub fn formatMemorySize(size: u64, buf: []u8) []const u8 {
    return formatFileSize(@intCast(size), buf);
}

// ============================================================================
// Tests
// ============================================================================

test "GGUF magic constant is correct" {
    // "GGUF" in ASCII: G=0x47, G=0x47, U=0x55, F=0x46
    // In little-endian u32: 0x46554747
    try std.testing.expectEqual(@as(u32, 0x46554747), GGUF_MAGIC);
}

test "formatFileSize formats correctly" {
    var buf: [32]u8 = undefined;

    const bytes = formatFileSize(512, &buf);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "512") != null);

    const kb = formatFileSize(2048, &buf);
    try std.testing.expect(std.mem.indexOf(u8, kb, "KB") != null);

    const mb = formatFileSize(5 * 1024 * 1024, &buf);
    try std.testing.expect(std.mem.indexOf(u8, mb, "MB") != null);

    const gb = formatFileSize(2 * 1024 * 1024 * 1024, &buf);
    try std.testing.expect(std.mem.indexOf(u8, gb, "GB") != null);
}

test "QuantizationType.bitsPerWeight returns correct values" {
    try std.testing.expectEqual(@as(f32, 32.0), QuantizationType.F32.bitsPerWeight());
    try std.testing.expectEqual(@as(f32, 16.0), QuantizationType.F16.bitsPerWeight());
    try std.testing.expectEqual(@as(f32, 4.5), QuantizationType.Q4_K_M.bitsPerWeight());
}

test "ModelArchitecture.fromString works" {
    try std.testing.expectEqual(ModelArchitecture.llama, ModelArchitecture.fromString("llama"));
    try std.testing.expectEqual(ModelArchitecture.llama, ModelArchitecture.fromString("LLAMA"));
    try std.testing.expectEqual(ModelArchitecture.gemma, ModelArchitecture.fromString("gemma"));
    try std.testing.expectEqual(ModelArchitecture.unknown, ModelArchitecture.fromString("unknown_arch"));
}
