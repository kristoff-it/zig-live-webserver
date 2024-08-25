const std = @import("std");
const options = @import("options");
const fs = std.fs;
const mime = @import("mime");
const Allocator = std.mem.Allocator;
const Reloader = @import("Reloader.zig");
const not_found_html = @embedFile("404.html");
const reload_js = @embedFile("watcher/reload.js");
const assert = std.debug.assert;
const websocket = @import("websocket.zig");

const log = std.log.scoped(.server);
pub const std_options: std.Options = .{
    // .log_level = .warn,
    .log_level = .info,
    .log_scope_levels = options.log_scope_levels,
};

var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};

pub fn main() void {
    const gpa = general_purpose_allocator.allocator();
    const args = std.process.argsAlloc(gpa) catch |err| failWithError("Parse arguments", err);
    log.debug("server args: {s}", .{args});

    if (args.len <= 6) {
        failWithError("Parse arguments:", error.NotEnoughArguments);
    }

    const zig_exe = args[1];
    const root_dir_path = args[2];
    const listen_port = std.fmt.parseInt(u16, args[3], 10) catch |err| failWithError("Parse port", err);
    const rebuild_step_name = args[4];
    const debug = std.mem.eql(u8, args[5], "Debug");
    const input_dirs = args[6..];

    const reloader = Reloader.start(gpa, zig_exe, root_dir_path, input_dirs, rebuild_step_name) catch |err| {
        failWithError("Starting reloader", err);
    };
    _ = debug;

    var root_dir: fs.Dir = fs.cwd().openDir(root_dir_path, .{}) catch |err| failWithError("open serving directory", err);
    defer root_dir.close();

    {
        var request_pool: std.Thread.Pool = undefined;
        request_pool.init(.{
            .allocator = gpa,
        }) catch |err| failWithError("Start webserver threads", err);

        const address = std.net.Address.parseIp("127.0.0.1", listen_port) catch |err| failWithError("obtain ip", err);
        var tcp_server = address.listen(.{
            .reuse_port = true,
            .reuse_address = true,
        }) catch |err| failWithError("listen", err);
        defer tcp_server.deinit();

        std.debug.print("\x1b[2K\rServing website at http://{any}/" ++ options.frame_path ++ "/\n", .{tcp_server.listen_address.in});

        accept: while (true) {
            const request = gpa.create(Request) catch |err| {
                failWithError("allocating request", err);
            };
            request.gpa = gpa;
            request.public_dir = root_dir;
            request.reloader = reloader;
            request.conn = tcp_server.accept() catch |err| {
                switch (err) {
                    error.ConnectionAborted, error.ConnectionResetByPeer => {
                        log.warn("{s} on lister accept", .{@errorName(err)});
                        gpa.destroy(request);
                        continue :accept;
                    },
                    else => {},
                }
                failWithError("accept connection", err);
            };

            request_pool.spawn(Request.handle, .{request}) catch |err| {
                log.err("Error spawning request response thread: {s}", .{@errorName(err)});
                request.conn.stream.close();
                gpa.destroy(request);
            };
        }
    }
}

pub fn failWithError(operation: []const u8, err: anytype) noreturn {
    std.debug.print("Unrecoverable Failure: {s} encountered error {s}.\n", .{ operation, @errorName(err) });
    std.process.exit(1);
}

const embed_files = [_][]const u8{
    "style.css",
    "script.js",
    "icon.svg",
};

const Request = struct {
    // Fields are in initialization order.
    gpa: std.mem.Allocator,
    public_dir: std.fs.Dir,
    reloader: *Reloader,
    conn: std.net.Server.Connection,
    connection_hijacked: bool,
    allocator_arena: std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,
    http: std.http.Server.Request,

    // Not initialized in this code but utilized by http server.
    buffer: [1024]u8,

    fn handle(req: *Request) void {
        defer req.gpa.destroy(req);
        req.connection_hijacked = false;
        defer if (!req.connection_hijacked) {
            req.conn.stream.close();
        };

        req.allocator_arena = std.heap.ArenaAllocator.init(req.gpa);
        defer req.allocator_arena.deinit();
        req.allocator = req.allocator_arena.allocator();

        var http_server = std.http.Server.init(req.conn, &req.buffer);
        req.http = http_server.receiveHead() catch |err| {
            if (err != error.HttpConnectionClosing) {
                log.err("Error with getting request headers:{s}", .{@errorName(err)});
                // TODO: We're supposed to server an error to the request on some of these
                // error types, but the http server doesn't give us the response to write to,
                // so we're not going to bother doing it manually.
            }
            return;
        };

        const path = req.http.head.target;

        std.debug.print(">>{s}<<\n", .{path});
        (handle_req: {
            if (std.mem.startsWith(u8, path, "/" ++ options.frame_path ++ "/")) {
                break :handle_req req.handleEmbed("index.html", "text/html");
            } else inline for (embed_files) |embed_file| {
                if (std.mem.eql(u8, path, "/__live_webserver/" ++ embed_file)) {
                    const mime_type = mime.extension_map.get(fs.path.extension(path)) orelse
                        .@"application/octet-stream";
                    break :handle_req req.handleEmbed(embed_file, @tagName(mime_type));
                }
            } else if (std.mem.eql(u8, path, "/__live_webserver/reload.js")) {
                break :handle_req req.handleReloadJs();
            } else if (std.mem.eql(u8, path, "/__live_webserver/ws")) {
                break :handle_req req.handleWebsocket();
            } else {
                break :handle_req req.handleFile();
            }
        }) catch |err| {
            log.warn("Error {s} responding to request from {any} for {s}", .{ @errorName(err), req.conn.address, path });
        };
    }

    const common_headers = [_]std.http.Header{
        .{ .name = "connection", .value = "close" },
        .{ .name = "Cache-Control", .value = "no-cache, no-store, must-revalidate" },
    };

    fn handleEmbed(req: *Request, comptime filename: []const u8, content_type: []const u8) !void {
        try req.http.respond(@embedFile(filename), .{
            .extra_headers = &(.{
                .{ .name = "content-type", .value = content_type },
            } ++ common_headers),
        });
    }

    fn handleReloadJs(req: *Request) !void {
        _ = req;
        @panic("reload.js not implemented yet!!");
    }
    fn handleWebsocket(req: *Request) !void {
        const ws = try websocket.Connection.init(&req.http);
        try req.reloader.spawnConnection(ws);
        req.connection_hijacked = true;
    }
    fn handleFile(req: *Request) !void {
        var path = req.http.head.target;

        if (std.mem.indexOf(u8, path, "..")) |_| {
            req.serveError("'..' not allowed in URLs", .bad_request);

            // TODO: Allow relative paths while ensuring that directories
            // outside of the served directory can never be accessed.
            return error.BadPath;
        }

        if (std.mem.endsWith(u8, path, "/")) {
            path = try std.fmt.allocPrint(req.allocator, "{s}{s}", .{
                path,
                "index.html",
            });
        }

        if (path.len < 1 or path[0] != '/') {
            if (std.mem.indexOf(u8, path, "..")) |_| {
                req.serveError("bad request path.", .bad_request);
                return error.BadPath;
            }
        }

        path = path[1 .. std.mem.indexOfScalar(u8, path, '?') orelse path.len];

        const mime_type = mime.extension_map.get(fs.path.extension(path)) orelse
            .@"application/octet-stream";

        const file = req.public_dir.openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                // Original code does this, but it's better handled by the directory
                // case below, right?
                // if (std.mem.endsWith(u8, path, "/")) {
                req.serveError(null, .not_found);
                if (std.mem.eql(u8, path, "favicon.ico")) {
                    return; // Surpress error logging.
                }
                return err;
                // }
                // return req.handleAppendSlash();
            },
            else => {
                req.serveError("accessing resource", .internal_server_error);
                return err;
            },
        };
        defer file.close();

        const metadata = file.metadata() catch |err| {
            req.serveError("accessing resource", .internal_server_error);
            return err;
        };
        if (metadata.kind() == .directory) {
            return req.handleAppendSlash();
        }

        const content_type = switch (mime_type) {
            inline else => |mt| blk: {
                if (std.mem.startsWith(u8, @tagName(mt), "text")) {
                    break :blk @tagName(mt) ++ "; charset=utf-8";
                }
                break :blk @tagName(mt);
            },
        };

        var buffer: [4000]u8 = undefined;
        var response = req.http.respondStreaming(.{
            .send_buffer = &buffer,
            // .content_length = metadata.size(),
            .respond_options = .{
                .extra_headers = &(.{
                    .{ .name = "content-type", .value = content_type },
                } ++ common_headers),
            },
        });
        try response.writer().writeFile(file);
        return response.end();
    }

    fn handleAppendSlash(req: *Request) !void {
        const location = try std.fmt.allocPrint(
            req.allocator,
            "{s}/",
            .{req.http.head.target},
        );
        try req.http.respond("redirecting...", .{
            .status = .see_other,
            .extra_headers = &(.{
                .{ .name = "location", .value = location },
                .{ .name = "content-type", .value = "text/html" },
            } ++ common_headers),
        });
    }

    fn serveError(req: *Request, comptime reason: ?[]const u8, comptime status: std.http.Status) void {
        const sep = if (reason) |_| ": " else ".";
        const text = std.fmt.comptimePrint("{d} {s}{s}{s}", .{ @intFromEnum(status), comptime status.phrase().?, sep, reason orelse "" });
        req.http.respond(text, .{
            .status = status,
            .extra_headers = &(.{
                .{ .name = "content-type", .value = "text/text" },
            } ++ common_headers),
        }) catch |err| {
            log.warn("Error {s} serving error text {s}", .{ @errorName(err), text });
        };
    }
};

test {
    _ = websocket;
}
