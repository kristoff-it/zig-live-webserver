const zine = @This();
const std = @import("std");

// This file only contains definitions that are considered Zine's public
// interface. Zine's main build function is in another castle!
pub const build = @import("build/tools.zig").build;

pub const DevelopmentServerOptions = struct {
    website_step: *std.Build.Step,
    host: []const u8,
    port: u16 = 1990,
    input_dirs: []const []const u8,
    debug: bool = false,
};
pub fn addDevelopmentServer(
    b: *std.Build,
    step: *std.Build.Step,
    opts: DevelopmentServerOptions,
) void {
    var optimize: std.builtin.OptimizeMode = .ReleaseFast;
    var scopes: []const []const u8 = &.{};

    if (opts.debug) {
        optimize = if (b.option(
            bool,
            "debug",
            "build Zine tools in debug mode",
        ) orelse false) .Debug else .ReleaseFast;
        scopes = b.option(
            []const []const u8,
            "scope",
            "logging scopes to enable",
        ) orelse &.{};
    }

    const zine_dep = b.dependencyFromBuildZig(zine, .{
        .optimize = optimize,
        .scope = scopes,
    });

    const server_exe = zine_dep.artifact("server");
    const run_server = b.addRunArtifact(server_exe);
    run_server.addArg(b.graph.zig_exe); // #1
    run_server.addArg(b.install_path); // #2
    run_server.addArg(b.fmt("{d}", .{opts.port})); // #3
    run_server.addArg(opts.website_step.name); // #4
    run_server.addArg(@tagName(optimize)); // #5

    for (opts.input_dirs) |dir| {
        run_server.addArg(dir); // #6..
    }

    if (opts.website_step.id != .top_level) {
        std.debug.print("Website step given to 'addDevelopmentServer' needs to be a top-level step (created via b.step()) because the server executable needs to be able to invoke it to rebuild the website on file change.\n\n", .{});

        std.process.exit(1);
    }

    run_server.step.dependOn(opts.website_step);
    step.dependOn(&run_server.step);
}
