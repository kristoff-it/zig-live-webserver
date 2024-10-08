const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const scopes: []const []const u8 = b.option(
        []const []const u8,
        "scope",
        "logging scopes to enable",
    ) orelse &.{};

    const options = blk: {
        const options = b.addOptions();
        const out = options.contents.writer();
        try out.writeAll(
            \\// module = live-webserver
            \\const std = @import("std");
            \\pub const log_scope_levels: []const std.log.ScopeLevel = &.{
            \\
        );
        for (scopes) |l| try out.print(
            \\.{{.scope = .{s}, .level = .debug}},
        , std.zig.fmtId(l));
        try out.writeAll("};");
        try out.print("pub const frame_path = \"{s}\";", .{"%E2%9A%A1"}); // Setup for making this configurable. 127.0.0.1:1990/🗲/#/⚡ http://127.0.0.1:1990/%F0%9F%97%B2/#/%E2%9A%A1
        break :blk options.createModule();
    };

    const server = b.addExecutable(.{
        .name = "server",
        .root_source_file = b.path("src/main.zig"),
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

    /////

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
