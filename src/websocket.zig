const std = @import("std");

const log = std.log.scoped(.websockets);

pub const Connection = struct {
    gpa: std.mem.Allocator,
    stream: std.net.Stream,
    write_lock: std.Thread.Mutex = .{},

    pub fn spawn(gpa: std.mem.Allocator, stream: std.net.Stream) void {
        trySpawn(gpa, stream) catch |err| {
            log.warn("Error spawning websocket: {s}", .{@errorName(err)});
        };
    }
    pub fn trySpawn(gpa: std.mem.Allocator, stream: std.net.Stream) !void {
        errdefer stream.close();

        const conn = try gpa.create(Connection);
        errdefer gpa.destroy(conn);

        conn.* = .{
            .gpa = gpa,
            .stream = stream,
        };

        const ws = try std.Thread.spawn(.{}, Connection.readThread, .{
            conn,
        });
        ws.detach();

        // Have either the writing thread or the reading thread spawn the other and do a join at the end.
        // That thread can be the done to delete the connection from gpa.
        // Writer thread watches for changes to post about, but doesn't own stream writing.  That is because
        // the read thread needs to respond to pings.  So instead any writes must be surrounded with use of write_lock.
        // Writer thread waits for updates with a timeout, and sends a ping on the timeout. If no pong since last ping, kill the conn.
    }

    fn readThread(conn: *Connection) void {
        conn.readLoop() catch {
            // _ = err; // TODO
            @panic("read loop error");
        };
    }
    fn readLoop(conn: *Connection) !void {
        const reader = conn.stream.reader();
        // We're only handling simple signals here.  Ok to make much larger if a real use case arises.
        // Just don't always keep the buffer in memory always if messages becomes more than a few kb.
        var buffer: [100]u8 = undefined;
        var current_length: u64 = 0;
        while (true) {
            const header = try Header.read(reader);
            if (current_length > 0 and (header.op_code == .binary or header.op_code == .text)) {
                return error.ExpectedContinuation;
            }
            if (header.payload_len + current_length > buffer.len) {
                return error.PayloadUnreasonablyLarge;
            }
            try reader.readNoEof((&buffer)[current_length..header.payload_len]);

            if (header.mask) |mask| {
                for (0.., (&buffer)[current_length..header.payload_len]) |i, *b| {
                    b.* ^= mask[i % 4];
                }
            }
            current_length += header.payload_len;

            if (header.finish) {
                std.debug.print("Got msg {any}: {s}\n", .{ header, (&buffer)[0..current_length] });
                current_length = 0;
            }
        }
    }
};

const Header = struct {
    finish: bool,
    op_code: OpCode,
    payload_len: u64,
    mask: ?[4]u8,

    const OpCode = enum(u4) {
        continuation = 0,
        text = 1,
        binary = 2,
        close = 8,
        ping = 9,
        pong = 10,
    };

    const Partial = packed struct(u16) {
        payload_len: enum(u7) {
            u16_len = 126,
            u64_len = 127,
            _,
        },
        masked: bool,
        op_code: u4,
        reserved: u3,
        fin: bool,
    };
    fn read(reader: anytype) !Header {
        const partial: Partial = @bitCast(try reader.readInt(u16, .big));
        var r: Header = undefined;
        r.finish = partial.fin;

        inline for (std.meta.fields(OpCode)) |field| {
            if (field.value == partial.op_code) {
                r.op_code = @field(OpCode, field.name);
                break;
            }
        } else {
            return error.InvalidHeader;
        }

        r.payload_len = switch (partial.payload_len) {
            .u16_len => try reader.readInt(u16, .big),
            .u64_len => try reader.readInt(u64, .big),
            else => |v| @intFromEnum(v),
        };

        if (partial.masked) {
            r.mask = try reader.readBytesNoEof(4);
        } else {
            r.mask = null;
        }

        return r;
    }

    fn write(h: Header, writer: anytype) !void {
        var p: Partial = .{
            .payload_len = undefined,
            .masked = if (h.mask) |_| true else false,
            .op_code = @intFromEnum(h.op_code),
            .reserved = 0,
            .fin = h.finish,
        };

        if (h.payload_len < 126) {
            p.payload_len = @enumFromInt(h.payload_len);
        } else if (h.payload_len <= std.math.maxInt(u16)) {
            p.payload_len = .u16_len;
        } else {
            p.payload_len = .u64_len;
        }

        try writer.writeInt(u16, @bitCast(p), .big);
        switch (p.payload_len) {
            .u16_len => try writer.writeInt(u16, @intCast(h.payload_len), .big),
            .u64_len => try writer.writeInt(u64, h.payload_len, .big),
            else => {},
        }
        if (h.mask) |mask| {
            try writer.writeAll(&mask);
        }
    }
};

fn testHeader(header_truth: Header, buffer_truth: []const u8) !void {
    {
        var stream = std.io.fixedBufferStream(buffer_truth);
        const header_result = Header.read(stream.reader());
        try std.testing.expectEqualDeep(header_truth, header_result);
        try std.testing.expectEqual(buffer_truth.len, stream.getPos()); // consumed whole header
    }
    {
        var b: [20]u8 = undefined;
        var stream = std.io.fixedBufferStream(&b);
        try header_truth.write(stream.writer());
        try std.testing.expectEqualSlices(u8, buffer_truth, stream.getWritten());
    }
}

test Header {
    // Finish
    try testHeader(.{ .finish = true, .op_code = .continuation, .payload_len = 0, .mask = null }, &[_]u8{ 1 << 7, 0 });
    // Op code
    try testHeader(.{ .finish = false, .op_code = .text, .payload_len = 0, .mask = null }, &[_]u8{ 1, 0 });
    // Payload len
    try testHeader(.{ .finish = false, .op_code = .continuation, .payload_len = 125, .mask = null }, &[_]u8{ 0, 125 });
    try testHeader(.{ .finish = false, .op_code = .continuation, .payload_len = 126, .mask = null }, &[_]u8{ 0, 126, 0, 126 });
    try testHeader(.{ .finish = false, .op_code = .continuation, .payload_len = 65_535, .mask = null }, &[_]u8{ 0, 126, 255, 255 });
    try testHeader(.{ .finish = false, .op_code = .continuation, .payload_len = 65_536, .mask = null }, &[_]u8{ 0, 127, 0, 0, 0, 0, 0, 1, 0, 0 });
    // Mask
    try testHeader(.{ .finish = false, .op_code = .continuation, .payload_len = 0, .mask = .{ 1, 2, 3, 4 } }, &[_]u8{ 0, 1 << 7, 1, 2, 3, 4 });
    // Bit of everthing
    try testHeader(.{ .finish = true, .op_code = .binary, .payload_len = 126, .mask = .{ 1, 2, 3, 4 } }, &[_]u8{ (1 << 7) | 2, 1 << 7 | 126, 0, 126, 1, 2, 3, 4 });
}
