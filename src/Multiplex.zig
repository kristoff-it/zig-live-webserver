const std = @import("std");
const websocket = @import("websocket.zig");

const log = std.log.scoped(.multiplex);

const Multiplex = @This();

gpa: std.mem.Allocator,

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

pub fn create(gpa: std.mem.Allocator) !*Multiplex {
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
        .timer = try std.time.Timer.start(),
        .connections = std.ArrayList(*Connection).init(gpa),
        .encoded_state = encoded_state,
    };

    const loop_thread = try std.Thread.spawn(.{}, Multiplex.loop, .{
        m,
    });
    loop_thread.detach();

    return m;
}

fn loop(m: *Multiplex) noreturn {
    // Handles tasks on a delay
    m.lock.lock();

    const now = m.timer.read();
    while (true) {
        const wait_time = @min(
            m.build_at orelse std.math.maxInt(u64),
            m.output_at orelse std.math.maxInt(u64),
        ) -| now;
        m.condition.timedWait(&m.lock, wait_time) catch {};
    }
}

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
