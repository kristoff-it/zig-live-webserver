const std = @import("std");
const live_webserver = @import("live-webserver");

pub fn build(b: *std.Build) void {
    b.installFile("src/index.html", "index.html");

    const serve_step = b.step("serve", "serves on development server");
    live_webserver.addDevelopmentServer(b, serve_step, .{
        .website_step = b.getInstallStep(),
        .host = "localhost",
        .input_dirs = &.{"src"},
        .debug = true,
    });
}
