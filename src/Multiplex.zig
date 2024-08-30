const std = @import("std");
const builtin = @import("builtin");
const root = @import("root");
const websocket = @import("websocket.zig");
const Watcher = switch (builtin.target.os.tag) {
    .linux => @import("watcher/LinuxWatcher.zig"),
    .macos => @import("watcher/MacosWatcher.zig"),
    .windows => @import("watcher/WindowsWatcher.zig"),
    else => @compileError("unsupported platform"),
};

const log = std.log.scoped(.multiplex);
const debounce_time = std.time.ns_per_ms * 10;

const Multiplex = @This();

gpa: std.mem.Allocator,
zig_exe: []const u8,
out_dir_path: []const u8,
in_dir_paths: []const []const u8,
website_step_name: []const u8,

lock: std.Thread.Mutex = .{},
condition: std.Thread.Condition = .{},

// Everything past this point needs to hold lock to mutate;
timer: std.time.Timer,

build_at: ?u64 = null,
output_at: ?u64 = null,

connections: std.ArrayList(*Connection),

iteration: u64 = 0,
encoded_state: []const u8,

const Connection = struct {
    ws: websocket.Connection,
    iteration_sent: ?u64 = null,

    outstanding_read: bool,
    outstanding_write: bool = false,
    closing: bool = false,
};

pub fn create(
    gpa: std.mem.Allocator,
    zig_exe: []const u8,
    out_dir_path: []const u8,
    in_dir_paths: []const []const u8,
    website_step_name: []const u8,
) !*Multiplex {
    const m = try gpa.create(Multiplex);

    const encoded_state = try gpa.dupe(u8,
        \\ {
        \\    "state": "live",
        \\    "file_changes": {},
        \\ }
    );
    errdefer gpa.free(encoded_state);

    m.* = .{
        .gpa = gpa,
        .zig_exe = zig_exe,
        .out_dir_path = out_dir_path,
        .in_dir_paths = in_dir_paths,
        .website_step_name = website_step_name,

        .timer = try std.time.Timer.start(),
        .connections = std.ArrayList(*Connection).init(gpa),
        .encoded_state = encoded_state,
    };

    const loop_thread = try std.Thread.spawn(.{}, Multiplex.loop, .{
        m,
    });
    loop_thread.detach();

    const watcher_thread = try std.Thread.spawn(.{}, Multiplex.runWatcher, .{
        m,
    });
    watcher_thread.detach();

    return m;
}

fn loop(m: *Multiplex) noreturn {
    // Handles tasks on a delay
    m.lock.lock();

    while (true) {
        const now = m.timer.read();
        if (m.build_at) |build_at| {
            if (now >= build_at) {
                std.debug.print("Fake build\n", .{});
                m.build_at = null;
            }
        }

        if (m.output_at) |output_at| {
            if (now >= output_at) {
                std.debug.print("Fake output\n", .{});
                m.output_at = null;
            }
        }

        const wait_time = @min(
            m.build_at orelse std.math.maxInt(u64),
            m.output_at orelse std.math.maxInt(u64),
        ) -| now;
        m.condition.timedWait(&m.lock, wait_time) catch {};
    }
}

//////////////////////////////////////////////////////
// File watching

fn runWatcher(m: *Multiplex) noreturn {
    var watcher = Watcher.init(m.gpa, m.out_dir_path, m.in_dir_paths) catch |err| {
        root.failWithError("Init file watching", err);
    };
    watcher.listen(m.gpa, m) catch |err| {
        root.failWithError("Watching files", err);
    };
}

pub fn onInputChange(m: *Multiplex, path: []const u8, name: []const u8) void {
    std.debug.print("INPUT CHANGE: {s}\n", .{path});
    _ = name;

    m.lock.lock();
    defer m.lock.unlock();

    m.build_at = m.timer.read() + debounce_time;
    m.condition.signal();
}

pub fn onOutputChange(m: *Multiplex, path: []const u8, name: []const u8) void {
    std.debug.print("OUTPUT CHANGE: {s}\n", .{path});
    _ = name;

    m.lock.lock();
    defer m.lock.unlock();

    m.output_at = m.timer.read() + debounce_time;
    m.condition.signal();
}

//////////////////////////////////////////////////////
// Connections

pub fn connect(m: *Multiplex, ws: websocket.Connection) !void {
    m.lock.lock();
    defer m.lock.unlock();

    errdefer {
        var mut_ws = ws;
        mut_ws.close();
    }

    const conn = try m.gpa.create(Connection);
    errdefer m.gpa.destroy(conn);

    conn.* = .{
        .ws = ws,
        .outstanding_read = true,
    };

    m.connections.append(conn) catch @panic("OOM");

    const read_thread = try std.Thread.spawn(.{}, Multiplex.readThread, .{
        m, conn,
    });
    read_thread.detach();

    m.sendState(conn);
}

fn sendState(m: *Multiplex, conn: *Connection) void {
    std.debug.assert(!m.lock.tryLock());

    if (conn.outstanding_write) {
        return;
    }
    if (conn.iteration_sent == m.iteration) {
        return;
    }
    if (conn.closing) {
        return;
    }

    conn.outstanding_write = true;
    const write_thread = std.Thread.spawn(.{}, Multiplex.writeThread, .{
        m, conn,
    }) catch |err| {
        m.closeConn(conn, err);
        return;
    };
    write_thread.detach();
}

fn readThread(m: *Multiplex, conn: *Connection) void {
    defer {
        m.lock.lock();
        defer m.lock.unlock();
        conn.outstanding_read = false;
        if (conn.closing) {
            m.closeConn(conn, error.AlreadyClosing);
        }
    }

    var buffer: [100]u8 = undefined;
    while (true) {
        const msg = conn.ws.readMessage(&buffer) catch |err| {
            m.lock.lock();
            defer m.lock.unlock();
            m.closeConn(conn, err);
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

fn writeThread(m: *Multiplex, conn: *Connection) void {
    defer {
        m.lock.lock();
        defer m.lock.unlock();
        conn.outstanding_write = false;
        if (conn.closing) {
            m.closeConn(conn, error.AlreadyClosing);
        }
    }

    var iteration_sent: ?u64 = null;
    while (true) {
        var iteration: u64 = undefined;
        var encoded_state: []const u8 = undefined;
        {
            m.lock.lock();
            defer m.lock.unlock();

            if (iteration_sent) |is| {
                conn.iteration_sent = is;
            }
            if (m.iteration == conn.iteration_sent) {
                return;
            }
            if (conn.closing) {
                return;
            }

            iteration = m.iteration;
            encoded_state = m.gpa.dupe(u8, m.encoded_state) catch @panic("OOM");
        }
        defer m.gpa.free(encoded_state);

        conn.ws.writeMessage(encoded_state, .text) catch |err| {
            m.lock.lock();
            defer m.lock.unlock();
            m.closeConn(conn, err);
            return;
        };
        iteration_sent = iteration;
    }
}

fn closeConn(m: *Multiplex, conn: *Connection, err: anyerror) void {
    std.debug.assert(!m.lock.tryLock());

    if (!conn.closing) {
        conn.closing = true;
        if (err != error.WebsocketClosed) {
            log.warn("Connection had error {s}", .{@errorName(err)});
        }
    }

    conn.ws.close();

    if (conn.outstanding_read or conn.outstanding_write) {
        return;
    }

    m.gpa.destroy(conn);

    const i = std.mem.indexOfScalar(*Connection, m.connections.items, conn);
    _ = m.connections.swapRemove(i.?);
}
