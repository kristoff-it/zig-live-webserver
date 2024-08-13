const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const scopes: []const []const u8 = b.option(
        []const []const u8,
        "scope",
        "logging scopes to enable",
    ) orelse &.{};

    const mode = .{ .target = target, .optimize = optimize };

    const options = blk: {
        const options = b.addOptions();
        const out = options.contents.writer();
        try out.writeAll(
            \\// module = zine
            \\const std = @import("std");
            \\pub const log_scope_levels: []const std.log.ScopeLevel = &.{
            \\
        );
        for (scopes) |l| try out.print(
            \\.{{.scope = .{s}, .level = .debug}},
        , std.zig.fmtId(l));
        try out.writeAll("};");
        break :blk options.createModule();
    };

    const server = b.addExecutable(.{
        .name = "server",
        .root_source_file = b.path("src/exes/server/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    if (target.result.os.tag == .macos) {
        server.linkFramework("CoreServices");
    }

    const mime = b.dependency("mime", .{
        .target = target,
        .optimize = optimize,
    });
    const ws = b.dependency("ws", .{
        .target = target,
        .optimize = optimize,
    });

    server.root_module.addImport("options", options);
    server.root_module.addImport("mime", mime.module("mime"));
    server.root_module.addImport("ws", ws.module("websocket"));

    b.installArtifact(server);
}
