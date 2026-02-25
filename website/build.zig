const std = @import("std");
const zine = @import("zine");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = target;
    _ = optimize;

    // Build the website
    const site_build = zine.website(b, .{
        .output_path = "docs",
        .website_root = b.path("."),
    });
    b.getInstallStep().dependOn(&site_build.step);

    // Serve the website (development)
    const site_serve = zine.serve(b, .{
        .website_root = b.path("."),
    });
    const serve_step = b.step("serve", "Start development server");
    serve_step.dependOn(&site_serve.step);
}
