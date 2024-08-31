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
const unique_server_id_decoded_len = 20;

gpa: std.mem.Allocator,
zig_exe: []const u8,
out_dir_path: []const u8,
in_dir_paths: []const []const u8,
website_step_name: []const u8,

/// Sent immediately to clients.  Clients will immediately refresh if a websocket connection
/// gives a different value.  This ensures state between different server runs doesn't get mixed.
unique_server_id: [std.base64.standard.Encoder.calcSize(unique_server_id_decoded_len)]u8,

lock: std.Thread.Mutex = .{},
condition: std.Thread.Condition = .{},

// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
// Everything past this point needs to hold lock to access
timer: std.time.Timer,

build_at: ?u64 = null,
output_at: ?u64 = null,

connections: std.ArrayList(*Connection),

iteration: u64 = 0,
encoded_state: []const u8,
change_counts: std.StringHashMap(u32),

// Can't cancel build because kill and collectOuptput/wait are not thread safe, ffs.
// Will need to make own output collector.
// build_canceled: bool = false,

// build owned by build thread, NOT the lock while build_process is not null.
building: bool = false,
build: struct {
    process: ?std.process.Child = null,
    std_out: std.ArrayList(u8),
    err_out: std.ArrayList(u8),
    term: std.process.Child.Term = .{
        .Unknown = 0,
    },
},
// If last build had an error, display it instead of watching output.
build_success: bool = true,

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

    const encoded_state = blk: {
        var writer: JsonWriter = .{};
        writer.init(gpa);
        writer.beginObject();
        writer.objectField("state");
        writer.write("live");
        writer.objectField("file_changes");
        writer.beginObject();
        writer.endObject();
        writer.endObject();
        break :blk try writer.toOwnedSlice();
    };
    errdefer gpa.free(m.encoded_state);

    m.* = .{
        .gpa = gpa,
        .zig_exe = zig_exe,
        .out_dir_path = out_dir_path,
        .in_dir_paths = in_dir_paths,
        .website_step_name = website_step_name,

        .timer = try std.time.Timer.start(),
        .connections = std.ArrayList(*Connection).init(gpa),
        .encoded_state = encoded_state,
        .change_counts = std.StringHashMap(u32).init(gpa),

        .build = .{
            .std_out = std.ArrayList(u8).init(gpa),
            .err_out = std.ArrayList(u8).init(gpa),
        },
        .unique_server_id = undefined,
    };

    {
        var usid: [unique_server_id_decoded_len]u8 = undefined;
        std.crypto.random.bytes(&usid);

        const written = std.base64.standard.Encoder.encode(&m.unique_server_id, &usid);
        std.debug.assert(written.len == m.unique_server_id.len);
    }

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
            // TODO: Would prefer to cancel and restart build, instead will wait for it to finish.
            if (now >= build_at and !m.building) {
                m.build_at = null;
                m.triggerBuild();
            }
        }

        if (m.output_at) |output_at| {
            if (now >= output_at) {
                m.output_at = null;

                if (!m.building and m.build_success) {
                    std.debug.print("Fake output\n", .{});
                    var writer: JsonWriter = .{};
                    writer.init(m.gpa);
                    writer.beginObject();
                    writer.objectField("state");
                    writer.write("live");
                    writer.objectField("file_changes");
                    writer.beginObject();
                    var iter = m.change_counts.iterator();
                    while (iter.next()) |entry| {
                        writer.objectField(entry.key_ptr.*);
                        writer.write(entry.value_ptr.*);
                    }
                    writer.endObject();
                    writer.endObject();
                    m.updateState(writer.toOwnedSlice());
                }
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
// Building

fn triggerBuild(m: *Multiplex) void {
    std.debug.assert(!m.lock.tryLock());
    std.debug.assert(!m.building);
    std.debug.assert(m.build.process == null);
    m.building = true;

    log.info("Starting build", .{});

    const args: []const []const u8 = &.{
        m.zig_exe,
        "build",
        m.website_step_name,
    };

    {
        var writer: JsonWriter = .{};
        writer.init(m.gpa);
        writer.beginObject();
        writer.objectField("state");
        writer.write("building");
        writer.endObject();
        m.updateState(writer.toOwnedSlice());
    }

    m.build.std_out.clearAndFree();
    m.build.err_out.clearAndFree();
    m.build.process = std.process.Child.init(args, m.gpa);
    m.build.process.?.stdout_behavior = .Pipe;
    m.build.process.?.stderr_behavior = .Pipe;
    m.build.process.?.spawn() catch |err| {
        m.internalBuildError(err);
        return;
    };

    const build_thread = std.Thread.spawn(.{}, Multiplex.buildThread, .{
        m,
    }) catch @panic("Can't start build thread.");
    build_thread.detach();
}

fn buildThread(m: *Multiplex) void {
    m.build.process.?.collectOutput(&m.build.std_out, &m.build.err_out, 1024 * 20) catch |err| {
        m.lock.lock();
        defer m.lock.unlock();
        m.internalBuildError(err);
        return;
    };

    m.build.term = m.build.process.?.wait() catch |err| {
        m.lock.lock();
        defer m.lock.unlock();
        m.internalBuildError(err);
        return;
    };

    m.lock.lock();
    defer m.lock.unlock();

    m.building = false;
    m.build_success = switch (m.build.term) {
        .Exited => |value| value == 0,
        else => false,
    };

    if (m.build_success) {
        log.info("Build success.", .{});
        m.output_at = m.timer.read() + debounce_time;
        m.condition.signal();
    } else {
        log.info("Build error.", .{});
        var writer: JsonWriter = .{};
        writer.init(m.gpa);
        writer.beginObject();
        writer.objectField("state");
        writer.write("error");
        writer.objectField("html");
        writer.write("TODO SHOW ERROR HERE");
        writer.endObject();
        m.updateState(writer.toOwnedSlice());
    }

    m.build.process = null;
}

fn internalBuildError(m: *Multiplex, err: anyerror) void {
    std.debug.assert(!m.lock.tryLock());
    log.info("Internal build error.", .{});

    m.build.std_out.clearAndFree();
    m.build.err_out.clearAndFree();
    m.build.err_out.appendSlice("Internal error running build: ") catch @panic("OOM");
    m.build.err_out.appendSlice(@errorName(err)) catch @panic("OOM");
    _ = m.build.process.?.kill() catch {};
    m.build.term = .{ .Unknown = 0 };

    m.building = false;
    m.build_success = false;
    m.build.process = null;

    var writer: JsonWriter = .{};
    writer.init(m.gpa);
    writer.beginObject();
    writer.objectField("state");
    writer.write("error");
    writer.objectField("html");
    writer.write(m.build.err_out.items);
    writer.endObject();
    m.updateState(writer.toOwnedSlice());
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
    std.debug.print("INPUT CHANGE: {s} {s}\n", .{ path, name });

    m.lock.lock();
    defer m.lock.unlock();

    m.build_at = m.timer.read() + debounce_time;
    m.condition.signal();
}

pub fn onOutputChange(m: *Multiplex, path: []const u8, name: []const u8) void {
    // Zig writes a file using a random name with no extension, then changes the name.
    if (std.mem.indexOfScalar(u8, name, '.') == null) {
        return;
    }

    const joined = std.fs.path.join(m.gpa, &.{ path, name }) catch @panic("OOM?");
    defer m.gpa.free(joined);

    const relative = std.fs.path.relative(m.gpa, m.out_dir_path, joined) catch @panic("OOM?");
    var relative_hijacked = false;
    defer if (!relative_hijacked) m.gpa.free(relative);

    log.debug("change detected on output file: {s}", .{relative});
    m.lock.lock();
    defer m.lock.unlock();

    const result = m.change_counts.getOrPut(relative) catch @panic("OOM");
    if (result.found_existing) {
        result.value_ptr.* += 1;
    } else {
        relative_hijacked = true;
        result.value_ptr.* = 1;
    }

    m.output_at = m.timer.read() + debounce_time;
    m.condition.signal();
}

//////////////////////////////////////////////////////
// Connections

pub fn connect(m: *Multiplex, ws: websocket.Connection) !void {
    var mut_ws = ws;
    errdefer {
        mut_ws.close();
    }

    {
        var writer: JsonWriter = .{};
        writer.init(m.gpa);
        writer.beginObject();
        writer.objectField("state");
        writer.write("unique_server_id");
        writer.objectField("id");
        writer.write(m.unique_server_id);
        writer.endObject();
        const msg = writer.toOwnedSlice() catch |err| return err;
        defer m.gpa.free(msg);
        mut_ws.writeMessage(msg, .text) catch |err| return err;
    }

    m.lock.lock();
    defer m.lock.unlock();

    const conn = try m.gpa.create(Connection);
    errdefer m.gpa.destroy(conn);

    conn.* = .{
        .ws = mut_ws,
        .outstanding_read = true,
    };

    m.connections.append(conn) catch @panic("OOM");

    const read_thread = try std.Thread.spawn(.{}, Multiplex.readThread, .{
        m, conn,
    });
    read_thread.detach();

    m.sendState(conn);
}

fn updateState(m: *Multiplex, maybe_new_state: JsonWriter.Error![]const u8) void {
    std.debug.assert(!m.lock.tryLock());

    const new_state = maybe_new_state catch |err| {
        @panic(@errorName(err));
        // TOOD: handle better, except maybe not if this isn't hit in practice.
    };

    m.gpa.free(m.encoded_state);
    m.iteration += 1;
    m.encoded_state = new_state;

    for (m.connections.items) |conn| {
        m.sendState(conn);
    }
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

        m.lock.lock();
        defer m.lock.unlock();
        if (std.mem.eql(u8, msg, "build")) {
            log.warn("Websocket triggering build.", .{});
            m.build_at = m.timer.read() + debounce_time;
            m.condition.signal();
        } else if (std.mem.eql(u8, msg, "noop")) {} else {
            for (msg) |*char| {
                if (!std.ascii.isPrint(char.*)) {
                    char.* = '.';
                }
            }
            log.warn("Unknown message via websocket: <{s}>", .{msg});
        }
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

//////////////////////////////////////////////////////
// Wrapped Json Writer

const JsonWriter = struct {
    const Writer = std.json.WriteStream(std.ArrayList(u8).Writer, .{ .checked_to_fixed_depth = 256 });
    const Error = Writer.Error;

    array_list: std.ArrayList(u8) = undefined,
    writer: Writer = undefined,
    err: Error!void = void{},

    fn init(w: *JsonWriter, gpa: std.mem.Allocator) void {
        w.array_list = std.ArrayList(u8).init(gpa);
        w.writer = std.json.writeStream(w.array_list.writer(), .{});
    }

    fn toOwnedSlice(w: *JsonWriter) Error![]u8 {
        errdefer w.array_list.deinit();
        w.err catch |err| return err;
        return w.array_list.toOwnedSlice();
    }

    fn beginObject(w: *JsonWriter) void {
        w.err catch return;
        w.err = w.writer.beginObject();
    }

    fn endObject(w: *JsonWriter) void {
        w.err catch return;
        w.err = w.writer.endObject();
    }

    fn objectField(w: *JsonWriter, key: []const u8) void {
        w.err catch return;
        w.err = w.writer.objectField(key);
    }

    fn write(w: *JsonWriter, value: anytype) void {
        w.err catch return;
        w.err = w.writer.write(value);
    }
};
