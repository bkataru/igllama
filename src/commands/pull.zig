const std = @import("std");
const Config = @import("../config.zig").Config;
const hf_hub = @import("hf-hub");

/// Download progress state for the progress bar
const DownloadState = struct {
    progress_bar: hf_hub.ProgressBar,
    filename: []const u8,
    was_resumed: bool,
    resume_bytes: u64,

    pub fn init(filename: []const u8, resume_bytes: u64) DownloadState {
        return .{
            .progress_bar = hf_hub.ProgressBar.init(),
            .filename = filename,
            .was_resumed = resume_bytes > 0,
            .resume_bytes = resume_bytes,
        };
    }
};

/// Module-level state for progress callback (not thread-safe, assumes single-threaded download)
/// NOTE: This pattern is safe because the pull command runs synchronously in a single thread.
/// If concurrent downloads are ever needed, this must be refactored to pass state via callback context.
var download_state: ?*DownloadState = null;

/// Progress callback that renders the progress bar
fn progressCallback(progress: hf_hub.DownloadProgress) void {
    if (download_state) |state| {
        state.progress_bar.render(progress);
    }
}

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
    if (args.len < 1) {
        try printUsage(stderr);
        return error.InvalidArguments;
    }

    var repo_id: ?[]const u8 = null;
    var specific_file: ?[]const u8 = null;
    var force_download: bool = false;
    var quiet: bool = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--file") or std.mem.eql(u8, arg, "-f")) {
            if (i + 1 < args.len) {
                i += 1;
                specific_file = args[i];
            } else {
                try stderr.print("Error: --file requires a filename argument\n", .{});
                return error.InvalidArguments;
            }
        } else if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-F")) {
            force_download = true;
        } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            quiet = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printHelp(stdout);
            return;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (repo_id == null) {
                repo_id = arg;
            }
        } else {
            try stderr.print("Error: Unknown option: {s}\n", .{arg});
            return error.InvalidArguments;
        }
    }

    if (repo_id == null) {
        try stderr.print("Error: Missing repository ID\n\n", .{});
        try printUsage(stderr);
        return error.InvalidArguments;
    }

    var cfg = Config.init(allocator) catch |err| {
        try stderr.print("Error initializing config: {}\n", .{err});
        return err;
    };
    defer cfg.deinit();

    if (!quiet) {
        try stdout.print("\nPulling from {s}...\n", .{repo_id.?});
        try stdout.flush();
    }

    // Initialize HuggingFace Hub client
    var client = hf_hub.HubClient.init(allocator, null) catch |err| {
        try handleNetworkError(stderr, err);
        return err;
    };
    defer client.deinit();

    if (specific_file) |filename| {
        // Download a specific file with progress
        try downloadFileWithProgress(
            allocator,
            &client,
            repo_id.?,
            filename,
            force_download,
            quiet,
            stdout,
            stderr,
        );
    } else {
        // List available GGUF files in the repo
        if (!quiet) {
            try stdout.print("Fetching available GGUF files...\n", .{});
            try stdout.flush();
        }

        const files = client.listGgufFiles(repo_id.?) catch |err| {
            try handleNetworkError(stderr, err);
            try stderr.print("Make sure the repository exists and contains GGUF files.\n", .{});
            return err;
        };
        defer client.freeFileInfoSlice(files);

        if (files.len == 0) {
            try stderr.print("No GGUF files found in repository.\n", .{});
            return;
        }

        try stdout.print("\nAvailable GGUF files:\n\n", .{});

        // Display files with size information
        for (files, 0..) |file, idx| {
            var size_buf: [32]u8 = undefined;
            const size_str = if (file.size) |sz|
                hf_hub.formatBytes(sz, &size_buf)
            else
                "unknown size";

            try stdout.print("  [{d}] {s}", .{ idx + 1, file.filename });
            try stdout.print("  ({s})\n", .{size_str});
        }

        try stdout.print("\nTo download a specific file, use:\n", .{});
        try stdout.print("  igllama pull {s} --file <filename>\n\n", .{repo_id.?});

        // If there's only one file, offer to download it
        if (files.len == 1) {
            try stdout.print("Only one GGUF file available. Downloading...\n\n", .{});
            try stdout.flush();

            try downloadFileWithProgress(
                allocator,
                &client,
                repo_id.?,
                files[0].filename,
                force_download,
                quiet,
                stdout,
                stderr,
            );
        }
    }

    if (!quiet) {
        try stdout.print("\nDone.\n", .{});
    }
}

fn downloadFileWithProgress(
    allocator: std.mem.Allocator,
    client: *hf_hub.HubClient,
    repo_id: []const u8,
    filename: []const u8,
    force_download: bool,
    quiet: bool,
    stdout: anytype,
    stderr: anytype,
) !void {
    // Get file metadata first to show total size
    const file_info: ?hf_hub.FileInfo = client.getFileMetadata(repo_id, filename, "main") catch null;

    if (file_info) |info| {
        if (!quiet) {
            var size_buf: [32]u8 = undefined;
            const size_str = if (info.size) |sz|
                hf_hub.formatBytes(sz, &size_buf)
            else
                "unknown size";
            try stdout.print("Downloading: {s} ({s})\n", .{ filename, size_str });
            try stdout.flush();
        }
    } else {
        if (!quiet) {
            try stdout.print("Downloading: {s}\n", .{filename});
            try stdout.flush();
        }
    }

    // Check for existing partial download to display resume info
    const output_path = try std.fs.path.join(allocator, &.{ ".", filename });
    defer allocator.free(output_path);

    const part_path = try std.fmt.allocPrint(allocator, "{s}.part", .{output_path});
    defer allocator.free(part_path);

    var resume_bytes: u64 = 0;
    if (!force_download) {
        // Check if file already exists
        if (std.fs.cwd().statFile(output_path)) |stat| {
            if (!quiet) {
                var size_buf: [32]u8 = undefined;
                try stdout.print("File already exists ({s}). Use --force to re-download.\n", .{
                    hf_hub.formatBytes(stat.size, &size_buf),
                });
            }
            return;
        } else |_| {}

        // Check for partial download
        if (std.fs.cwd().statFile(part_path)) |stat| {
            resume_bytes = stat.size;
            if (!quiet) {
                var size_buf: [32]u8 = undefined;
                try stdout.print("Resuming download from {s}...\n", .{
                    hf_hub.formatBytes(resume_bytes, &size_buf),
                });
                try stdout.flush();
            }
        } else |_| {}
    } else {
        // Force download - delete any existing partial file
        std.fs.cwd().deleteFile(part_path) catch {};
        std.fs.cwd().deleteFile(output_path) catch {};
    }

    // Set up progress state
    var state = DownloadState.init(filename, resume_bytes);
    download_state = &state;
    defer download_state = null;

    // Hide cursor during download for cleaner progress bar
    if (!quiet) {
        state.progress_bar.hideCursor();
    }
    defer if (!quiet) {
        state.progress_bar.showCursor();
        state.progress_bar.clearLine();
    };

    // Perform the download with progress callback
    const progress_cb: ?hf_hub.ProgressCallback = if (quiet) null else progressCallback;

    const result = client.downloadFile(repo_id, filename, progress_cb) catch |err| {
        if (!quiet) {
            state.progress_bar.renderError(filename, @errorName(err));
        }
        try handleNetworkError(stderr, err);
        return err;
    };
    defer allocator.free(result);

    // Get final file size
    const final_size = blk: {
        if (std.fs.cwd().statFile(result)) |stat| {
            break :blk stat.size;
        } else |_| {
            break :blk @as(u64, 0);
        }
    };

    if (!quiet) {
        state.progress_bar.complete(filename, final_size);
        try stdout.print("\nSaved to: {s}\n", .{result});
    }
}

fn handleNetworkError(stderr: anytype, err: anyerror) !void {
    switch (err) {
        error.NetworkError => {
            try stderr.print("Error: Network connection failed\n", .{});
            try stderr.print("  - Check your internet connection\n", .{});
            try stderr.print("  - Try again in a few moments\n", .{});
        },
        error.Timeout => {
            try stderr.print("Error: Connection timed out\n", .{});
            try stderr.print("  - The server may be slow or overloaded\n", .{});
            try stderr.print("  - Try again later\n", .{});
        },
        error.TlsError => {
            try stderr.print("Error: TLS/SSL error\n", .{});
            try stderr.print("  - There may be a certificate issue\n", .{});
            try stderr.print("  - Check your system's CA certificates\n", .{});
        },
        error.NotFound => {
            try stderr.print("Error: Repository or file not found\n", .{});
            try stderr.print("  - Check that the repository ID is correct\n", .{});
            try stderr.print("  - Verify the filename exists in the repository\n", .{});
        },
        error.Unauthorized => {
            try stderr.print("Error: Access denied\n", .{});
            try stderr.print("  - This repository may be private or gated\n", .{});
            try stderr.print("  - Set HF_TOKEN environment variable with your token\n", .{});
        },
        error.RateLimited => {
            try stderr.print("Error: Rate limited by HuggingFace\n", .{});
            try stderr.print("  - Wait a few minutes before trying again\n", .{});
            try stderr.print("  - Consider using an API token (HF_TOKEN)\n", .{});
        },
        error.IoError => {
            try stderr.print("Error: Failed to write file\n", .{});
            try stderr.print("  - Check disk space and permissions\n", .{});
        },
        error.OutOfMemory => {
            try stderr.print("Error: Out of memory\n", .{});
        },
        else => {
            try stderr.print("Error: {}\n", .{err});
        },
    }
}

fn printUsage(writer: anytype) !void {
    try writer.print("Usage: igllama pull <repo_id> [options]\n", .{});
    try writer.print("Example: igllama pull bartowski/Llama-3-8B-Instruct-GGUF\n", .{});
    try writer.print("\nRun 'igllama pull --help' for more options.\n", .{});
}

fn printHelp(writer: anytype) !void {
    try writer.print(
        \\igllama pull - Download GGUF models from HuggingFace Hub
        \\
        \\Usage:
        \\  igllama pull <repo_id> [options]
        \\
        \\Arguments:
        \\  <repo_id>              HuggingFace repository ID (e.g., bartowski/Llama-3-8B-Instruct-GGUF)
        \\
        \\Options:
        \\  -f, --file <name>      Download a specific file from the repository
        \\  -F, --force            Force re-download even if file exists
        \\  -q, --quiet            Suppress progress output
        \\  -h, --help             Show this help message
        \\
        \\Features:
        \\  - Beautiful progress bar with download speed and ETA
        \\  - Automatic resume for interrupted downloads
        \\  - File size display before download
        \\  - Lists available GGUF files if no specific file requested
        \\
        \\Examples:
        \\  # List GGUF files in a repository
        \\  igllama pull bartowski/Llama-3-8B-Instruct-GGUF
        \\
        \\  # Download a specific quantization
        \\  igllama pull bartowski/Llama-3-8B-Instruct-GGUF --file Llama-3-8B-Instruct-Q4_K_M.gguf
        \\
        \\  # Force re-download
        \\  igllama pull bartowski/Llama-3-8B-Instruct-GGUF -f model.gguf --force
        \\
        \\Environment:
        \\  HF_TOKEN               HuggingFace API token for private/gated models
        \\  HF_HOME                Custom cache directory (default: ~/.cache/huggingface)
        \\
    , .{});
}
