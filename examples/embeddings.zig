const std = @import("std");
const llama = @import("llama");
const slog = std.log.scoped(.embeddings);
const arg_utils = @import("utils/args.zig");

const Model = llama.Model;
const Context = llama.Context;

/// Embeddings generation example for semantic similarity.
/// This example shows how to:
/// - Generate text embeddings from a model
/// - Calculate cosine similarity between embeddings
/// - Use embeddings for semantic search
pub const Args = struct {
    model_path: [:0]const u8 = "models/all-MiniLM-L6-v2.Q4_K_M.gguf",
    text1: []const u8 = "The quick brown fox jumps over the lazy dog.",
    text2: []const u8 = "A fast auburn fox leaps above a sleepy canine.",
    threads: ?usize = null,
    gpu_layers: i32 = 0,
    normalize: bool = true,
};

/// Calculate cosine similarity between two vectors
fn cosineSimilarity(a: []const f32, b: []const f32) f32 {
    if (a.len != b.len or a.len == 0) return 0;

    var dot_product: f32 = 0;
    var norm_a: f32 = 0;
    var norm_b: f32 = 0;

    for (a, b) |va, vb| {
        dot_product += va * vb;
        norm_a += va * va;
        norm_b += vb * vb;
    }

    const denominator = @sqrt(norm_a) * @sqrt(norm_b);
    if (denominator == 0) return 0;

    return dot_product / denominator;
}

/// Normalize a vector to unit length
fn normalizeVector(vec: []f32) void {
    var sum: f32 = 0;
    for (vec) |v| {
        sum += v * v;
    }
    const norm = @sqrt(sum);
    if (norm > 0) {
        for (vec) |*v| {
            v.* /= norm;
        }
    }
}

pub fn run(alloc: std.mem.Allocator, args: Args) !void {
    llama.Backend.init();
    defer llama.Backend.deinit();

    // Suppress verbose logging
    llama.logSet(null, null);

    const stdout = std.io.getStdOut().writer();

    try stdout.print("Loading embedding model...\n", .{});

    var mparams = Model.defaultParams();
    mparams.n_gpu_layers = args.gpu_layers;

    const model = try Model.initFromFile(args.model_path.ptr, mparams);
    defer model.deinit();

    // Check if model supports embeddings
    const n_embd = model.nEmbd();
    if (n_embd == 0) {
        try stdout.print("Error: Model does not support embeddings.\n", .{});
        try stdout.print("Please use an embedding model (e.g., all-MiniLM, nomic-embed, etc.)\n", .{});
        return;
    }

    var cparams = Context.defaultParams();
    cparams.n_ctx = 512; // Embedding models typically need less context
    cparams.embeddings = true; // Enable embeddings mode

    const cpu_threads = try std.Thread.getCpuCount();
    cparams.n_threads = @intCast(args.threads orelse @min(cpu_threads, 4));
    cparams.n_threads_batch = @intCast(cpu_threads / 2);
    cparams.no_perf = true;

    const ctx = try Context.initWithModel(model, cparams);
    defer ctx.deinit();

    const vocab = model.vocab() orelse @panic("model missing vocab!");

    try stdout.print("Model loaded. Embedding dimension: {d}\n\n", .{n_embd});
    try stdout.print("Text 1: \"{s}\"\n", .{args.text1});
    try stdout.print("Text 2: \"{s}\"\n\n", .{args.text2});

    // Generate embeddings for text1
    var tokenizer1 = llama.Tokenizer.init(alloc);
    defer tokenizer1.deinit();
    try tokenizer1.tokenize(vocab, args.text1, true, true);

    var batch1 = llama.Batch.initOne(tokenizer1.getTokens());
    try batch1.decode(ctx);

    // Get embeddings for text1
    const embd1_ptr = ctx.getEmbeddingsSeq(0);
    if (embd1_ptr == null) {
        try stdout.print("Error: Could not get embeddings for text 1.\n", .{});
        try stdout.print("Make sure you're using an embedding model.\n", .{});
        return;
    }

    var embd1 = try alloc.alloc(f32, @intCast(n_embd));
    defer alloc.free(embd1);
    @memcpy(embd1, embd1_ptr.?[0..@intCast(n_embd)]);

    if (args.normalize) {
        normalizeVector(embd1);
    }

    // Clear context for text2
    ctx.kvCacheClear();

    // Generate embeddings for text2
    var tokenizer2 = llama.Tokenizer.init(alloc);
    defer tokenizer2.deinit();
    try tokenizer2.tokenize(vocab, args.text2, true, true);

    var batch2 = llama.Batch.initOne(tokenizer2.getTokens());
    try batch2.decode(ctx);

    // Get embeddings for text2
    const embd2_ptr = ctx.getEmbeddingsSeq(0);
    if (embd2_ptr == null) {
        try stdout.print("Error: Could not get embeddings for text 2.\n", .{});
        return;
    }

    var embd2 = try alloc.alloc(f32, @intCast(n_embd));
    defer alloc.free(embd2);
    @memcpy(embd2, embd2_ptr.?[0..@intCast(n_embd)]);

    if (args.normalize) {
        normalizeVector(embd2);
    }

    // Calculate similarity
    const similarity = cosineSimilarity(embd1, embd2);

    try stdout.print("---\n", .{});
    try stdout.print("Results:\n", .{});
    try stdout.print("  Text 1 tokens: {d}\n", .{tokenizer1.getTokens().len});
    try stdout.print("  Text 2 tokens: {d}\n", .{tokenizer2.getTokens().len});
    try stdout.print("  Embedding dim: {d}\n", .{n_embd});
    try stdout.print("  Normalized:    {}\n", .{args.normalize});
    try stdout.print("\n", .{});
    try stdout.print("  Cosine Similarity: {d:.4}\n", .{similarity});
    try stdout.print("\n", .{});

    // Interpret the similarity
    if (similarity > 0.9) {
        try stdout.print("  Interpretation: Very similar (nearly identical meaning)\n", .{});
    } else if (similarity > 0.7) {
        try stdout.print("  Interpretation: Similar (related meaning)\n", .{});
    } else if (similarity > 0.5) {
        try stdout.print("  Interpretation: Somewhat similar\n", .{});
    } else if (similarity > 0.3) {
        try stdout.print("  Interpretation: Loosely related\n", .{});
    } else {
        try stdout.print("  Interpretation: Different meanings\n", .{});
    }

    // Show first few embedding values
    try stdout.print("\n  First 5 embedding values (text 1): ", .{});
    for (embd1[0..@min(5, embd1.len)]) |v| {
        try stdout.print("{d:.4} ", .{v});
    }
    try stdout.print("...\n", .{});

    try stdout.print("  First 5 embedding values (text 2): ", .{});
    for (embd2[0..@min(5, embd2.len)]) |v| {
        try stdout.print("{d:.4} ", .{v});
    }
    try stdout.print("...\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() != .ok) @panic("memory leak detected");
    const alloc = gpa.allocator();

    const args_raw = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args_raw);

    const maybe_args = arg_utils.parseArgs(Args, args_raw[1..]) catch |err| {
        slog.err("Could not parse arguments: {}", .{err});
        arg_utils.printHelp(Args);
        return err;
    };

    const args = maybe_args orelse {
        arg_utils.printHelp(Args);
        return;
    };

    try run(alloc, args);
}

pub const std_options = std.Options{
    .log_level = std.log.Level.info,
};
