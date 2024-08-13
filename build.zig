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
};
pub fn addDevelopmentServer(
    b: *std.Build,
    zine_opts: ZineOptions,
    step: *std.Build.Step,
    server_opts: DevelopmentServerOptions,
) void {
    const zine_dep = b.dependencyFromBuildZig(zine, .{
        .optimize = zine_opts.optimize,
        .scope = zine_opts.scopes,
    });

    const server_exe = zine_dep.artifact("server");
    const run_server = b.addRunArtifact(server_exe);
    run_server.addArg(b.graph.zig_exe); // #1
    run_server.addArg(b.install_path); // #2
    run_server.addArg(b.fmt("{d}", .{server_opts.port})); // #3
    run_server.addArg(server_opts.website_step.name); // #4
    run_server.addArg(@tagName(zine_opts.optimize)); // #5

    for (server_opts.input_dirs) |dir| {
        run_server.addArg(dir); // #6..
    }

    if (server_opts.website_step.id != .top_level) {
        std.debug.print("Website step given to 'addDevelopmentServer' needs to be a top-level step (created via b.step()) because the server executable needs to be able to invoke it to rebuild the website on file change.\n\n", .{});

        std.process.exit(1);
    }

    run_server.step.dependOn(server_opts.website_step);
    step.dependOn(&run_server.step);
}

pub const ZineOptions = struct {
    optimize: std.builtin.OptimizeMode = .ReleaseFast,
    /// Logging scopes to enable, useful when
    /// building in debug mode to develop Zine.
    scopes: []const []const u8 = &.{},
};
fn defaultZineOptions(b: *std.Build, debug: bool) ZineOptions {
    var flags: ZineOptions = .{};
    if (debug) {
        flags.optimize = if (b.option(
            bool,
            "debug",
            "build Zine tools in debug mode",
        ) orelse false) .Debug else .ReleaseFast;
        flags.scopes = b.option(
            []const []const u8,
            "scope",
            "logging scopes to enable",
        ) orelse &.{};
    }
    return flags;
}
