const std = @import("std");
const builtin = @import("builtin");
const websocket = @import("websocket.zig");
const root = @import("root");
const AnsiRenderer = @import("AnsiRenderer.zig");
const Watcher = switch (builtin.target.os.tag) {
    .linux => @import("watcher/LinuxWatcher.zig"),
    .macos => @import("watcher/MacosWatcher.zig"),
    .windows => @import("watcher/WindowsWatcher.zig"),
    else => @compileError("unsupported platform"),
};

const Reloader = @This();

gpa: std.mem.Allocator,
zig_exe: []const u8,
out_dir_path: []const u8,
website_step_name: []const u8,
// debug: bool, // support any -D args?  Actually just use the ones passed into the original build.
watcher: Watcher,

// Lock on both current_status field, AND
// all Status.ref_count.
status_lock: std.Thread.Mutex = .{},
current_status: *Status,

const log = std.log.scoped(.reloader);

pub fn start(
    gpa: std.mem.Allocator,
    zig_exe: []const u8,
    out_dir_path: []const u8,
    in_dir_paths: []const []const u8,
    website_step_name: []const u8,
) !*Reloader {
    const reloader = try gpa.create(Reloader);
    errdefer gpa.destroy(reloader);

    const first_status = try gpa.create(Status);
    errdefer gpa.destroy(first_status);
    first_status.* = .{
        .current = .{ .serve = void{} },
    };

    reloader.* = .{
        .gpa = gpa,
        .zig_exe = zig_exe,
        .out_dir_path = out_dir_path,
        .website_step_name = website_step_name,
        .watcher = try Watcher.init(gpa, out_dir_path, in_dir_paths),
        .current_status = first_status,
    };

    const watch_thread = try std.Thread.spawn(.{}, Reloader.run, .{reloader});
    watch_thread.detach();

    return reloader;
}

fn run(reloader: *Reloader) void {
    reloader.watcher.listen(reloader.gpa, reloader) catch |err| {
        root.failWithError("Watch files", err);
    };
}

pub fn onInputChange(reloader: *Reloader, path: []const u8, name: []const u8) void {
    std.debug.print("INPUT CHANGE: {s}\n", .{path});
    _ = reloader;
    _ = name;
}

pub fn onOutputChange(reloader: *Reloader, path: []const u8, name: []const u8) void {
    std.debug.print("OUTPUT CHANGE: {s}\n", .{path});
    _ = reloader;
    _ = name;
}

pub fn spawnConnection(reloader: *Reloader, ws: websocket.Connection) !void {
    const conn = try reloader.gpa.create(Connection);
    errdefer reloader.gpa.destroy(conn);

    // const status = blk: {
    //     reloader.status_lock.lock();
    //     defer reloader.status_lock.lock();

    //     reloader.current_status.ref_count += 1;
    //     break :blk reloader.current_status;
    // };

    conn.* = .{
        .gpa = reloader.gpa,
        .ws = ws,
        .reloader = reloader,
    };

    const watch_thread = try std.Thread.spawn(.{}, Connection.watchThread, .{
        conn,
    });
    watch_thread.detach();
}

pub const Connection = struct {
    gpa: std.mem.Allocator,
    ws: websocket.Connection,
    reloader: *Reloader,

    fail: struct {
        lock: std.Thread.Mutex = .{},
        first_error: ?anyerror = null,
    } = .{},

    fn watchThread(conn: *Connection) void {
        defer conn.ws.close();
        defer conn.gpa.destroy(conn);

        const read_thread = std.Thread.spawn(.{}, Connection.readThread, .{conn}) catch |err| {
            log.err("Error creating read thread: {s}", .{@errorName(err)});
            return;
        };

        conn.watchLoop() catch |err| {
            conn.fail.lock.lock();
            defer conn.fail.lock.unlock();

            if (conn.fail.first_error == null) {
                conn.fail.first_error = err;
            }
            return;
        };

        read_thread.join();

        if (conn.fail.first_error) |first_error| {
            if (first_error != error.WebsocketClosed) {
                log.warn("Connection had error {s}", .{@errorName(first_error)});
            }
        }
    }

    fn watchLoop(conn: *Connection) !void {
        // current_status: *Status,
        _ = conn;
    }

    fn readThread(conn: *Connection) void {
        defer conn.ws.close();

        var buffer: [100]u8 = undefined;
        while (true) {
            const msg = conn.ws.readMessage(&buffer) catch |err| {
                conn.fail.lock.lock();
                defer conn.fail.lock.unlock();

                if (conn.fail.first_error == null) {
                    conn.fail.first_error = err;
                }
                return;
            };

            for (msg) |*char| {
                if (!std.ascii.isPrint(char.*)) {
                    char.* = '.';
                }
            }
            log.warn("Unknown message via websocket: <{s}>", .{msg});
        }
    }

    //     // Have either the writing thread or the reading thread spawn the other and do a join at the end.
    //     // That thread can be the done to delete the connection from gpa.
    //     // Writer thread watches for changes to post about, but doesn't own stream writing.  That is because
    //     // the read thread needs to respond to pings.  So instead any writes must be surrounded with use of write_lock.
    //     // Writer thread waits for updates with a timeout, and sends a ping on the timeout. If no pong since last ping, kill the conn.
};

const Status = struct {
    // Don't modify ref_count without holding status_lock.
    ref_count: u16 = 1,
    current: union(enum) {
        building: [400]u8,
        build_error: []u8,
        serve,
    },
};

/////////////////////////////////
/////////////////////////////////
/////////////////////////////////
/////////////////////////////////
/////////////////////////////////
/////////////////////////////////

// const std = @import("std");
// const ws = @import("ws");

// const ListenerFn = fn (self: *Reloader, path: []const u8, name: []const u8) void;
// const Watcher = switch (builtin.target.os.tag) {
//     .linux => @import("watcher/LinuxWatcher.zig"),
//     .macos => @import("watcher/MacosWatcher.zig"),
//     .windows => @import("watcher/WindowsWatcher.zig"),
//     else => @compileError("unsupported platform"),
// };

// gpa: std.mem.Allocator,
// ws_server: ws.Server,
// zig_exe: []const u8,
// out_dir_path: []const u8,
// website_step_name: []const u8,
// debug: bool,
// watcher: Watcher,

// clients_lock: std.Thread.Mutex = .{},
// clients: std.AutoArrayHashMapUnmanaged(*ws.Conn, void) = .{},

// pub fn init(
//     gpa: std.mem.Allocator,
//     zig_exe: []const u8,
//     out_dir_path: []const u8,
//     in_dir_paths: []const []const u8,
//     website_step_name: []const u8,
//     debug: bool,
// ) !Reloader {
//     const ws_server = try ws.Server.init(gpa, .{});

//     return .{
//         .gpa = gpa,
//         .zig_exe = zig_exe,
//         .out_dir_path = out_dir_path,
//         .ws_server = ws_server,
//         .website_step_name = website_step_name,
//         .debug = debug,
//         .watcher = try Watcher.init(gpa, out_dir_path, in_dir_paths),
//     };
// }

// pub fn listen(self: *Reloader) !void {
//     try self.watcher.listen(self.gpa, self);
// }

// pub fn onInputChange(self: *Reloader, path: []const u8, name: []const u8) void {
//     _ = name;
//     _ = path;
//     const args: []const []const u8 = if (self.debug) &.{
//         self.zig_exe,
//         "build",
//         self.website_step_name,
//         "-Ddebug",
//     } else &.{
//         self.zig_exe,
//         "build",
//         self.website_step_name,
//     };
//     log.debug("re-building! args: {s}", .{args});

//     const result = std.process.Child.run(.{
//         .allocator = self.gpa,
//         .argv = args,
//     }) catch |err| {
//         log.err("unable to run zig build: {s}", .{@errorName(err)});
//         return;
//     };
//     defer {
//         self.gpa.free(result.stdout);
//         self.gpa.free(result.stderr);
//     }

//     if (result.stdout.len > 0) {
//         log.info("zig build stdout: {s}", .{result.stdout});
//     }

//     if (result.stderr.len > 0) {
//         std.debug.print("{s}\n\n", .{result.stderr});
//     } else {
//         std.debug.print("File change triggered a successful build.\n", .{});
//     }

//     self.clients_lock.lock();
//     defer self.clients_lock.unlock();

//     const html_err = AnsiRenderer.renderSlice(self.gpa, result.stderr) catch |err| err: {
//         log.err("error rendering the ANSI-encoded error message: {s}", .{@errorName(err)});
//         break :err result.stderr;
//     };
//     defer self.gpa.free(html_err);

//     var idx: usize = 0;
//     while (idx < self.clients.entries.len) {
//         const conn = self.clients.entries.get(idx).key;

//         const BuildCommand = struct {
//             command: []const u8 = "build",
//             err: []const u8,
//         };

//         const cmd: BuildCommand = .{ .err = html_err };

//         var buf = std.ArrayList(u8).init(self.gpa);
//         defer buf.deinit();

//         std.json.stringify(cmd, .{}, buf.writer()) catch {
//             log.err("unable to generate ws message", .{});
//             return;
//         };

//         conn.write(buf.items) catch |err| {
//             log.debug("error writing to websocket: {s}", .{
//                 @errorName(err),
//             });
//             self.clients.swapRemoveAt(idx);
//             continue;
//         };

//         idx += 1;
//     }
// }
// pub fn onOutputChange(self: *Reloader, path: []const u8, name: []const u8) void {
//     if (std.mem.indexOfScalar(u8, name, '.') == null) {
//         return;
//     }
//     log.debug("re-load: {s}/{s}!", .{ path, name });

//     self.clients_lock.lock();
//     defer self.clients_lock.unlock();

//     var idx: usize = 0;
//     while (idx < self.clients.entries.len) {
//         const conn = self.clients.entries.get(idx).key;

//         const msg_fmt =
//             \\{{
//             \\  "command":"reload",
//             \\  "path":"{s}/{s}"
//             \\}}
//         ;

//         var buf: [4096]u8 = undefined;
//         const msg = std.fmt.bufPrint(&buf, msg_fmt, .{
//             path[self.out_dir_path.len..],
//             name,
//         }) catch {
//             log.err("unable to generate ws message", .{});
//             return;
//         };

//         conn.write(msg) catch |err| {
//             log.debug("error writing to websocket: {s}", .{
//                 @errorName(err),
//             });
//             self.clients.swapRemoveAt(idx);
//             continue;
//         };

//         idx += 1;
//     }
// }

// pub fn handleWs(self: *Reloader, req: *std.http.Server.Request, h: [20]u8) void {
//     var buf =
//         ("HTTP/1.1 101 Switching Protocols\r\n" ++
//         "Upgrade: websocket\r\n" ++
//         "Connection: upgrade\r\n" ++
//         "Sec-Websocket-Accept: 0000000000000000000000000000\r\n\r\n").*;

//     const key_pos = buf.len - 32;
//     _ = std.base64.standard.Encoder.encode(buf[key_pos .. key_pos + 28], h[0..]);

//     const stream = req.server.connection.stream;
//     stream.writeAll(&buf) catch return;

//     var conn = self.ws_server.newConn(stream);
//     var context: Handler.Context = .{ .watcher = self };
//     var handler = Handler.init(undefined, &conn, &context) catch return;
//     self.ws_server.handle(Handler, &handler, &conn);
// }

// const Handler = struct {
//     conn: *ws.Conn,
//     context: *Context,

//     const Context = struct {
//         watcher: *Reloader,
//     };

//     pub fn init(h: ws.Handshake, conn: *ws.Conn, context: *Context) !Handler {
//         _ = h;

//         const watcher = context.watcher;
//         watcher.clients_lock.lock();
//         defer watcher.clients_lock.unlock();
//         try watcher.clients.put(context.watcher.gpa, conn, {});

//         return Handler{
//             .conn = conn,
//             .context = context,
//         };
//     }

//     pub fn handle(self: *Handler, message: ws.Message) !void {
//         _ = self;
//         log.debug("ws message: {s}\n", .{message.data});
//     }

//     pub fn close(self: *Handler) void {
//         log.debug("ws connection was closed\n", .{});
//         const watcher = self.context.watcher;
//         watcher.clients_lock.lock();
//         defer watcher.clients_lock.unlock();
//         _ = watcher.clients.swapRemove(self.conn);
//     }
// };
