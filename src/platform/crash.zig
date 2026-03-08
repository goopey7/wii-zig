const http = @import("http.zig");
const c = @import("platform.zig").c;
const dolphin = @import("dolphin.zig");
const std = @import("std");

pub const CRASH_DUMP_HOST = "192.168.0.108";
pub const CRASH_DUMP_PORT: u16 = 9000;
pub const CRASH_DUMP_HOST_DOLPHIN = CRASH_DUMP_HOST;
pub const CRASH_DUMP_PORT_DOLPHIN: u16 = 9000;

var crash_socket: c_int = -1;
var target_addr: c.sockaddr_in = undefined;

pub const CrashDump = struct {
    pc: u32,
    exid: u32,
};

pub fn init() !void {
    const is_dolphin = dolphin.isDolphin();
    const host = if (is_dolphin) CRASH_DUMP_HOST_DOLPHIN else CRASH_DUMP_HOST;
    const port = if (is_dolphin) CRASH_DUMP_PORT_DOLPHIN else CRASH_DUMP_PORT;
    crash_socket = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
    if (crash_socket < 0) {
        return error.SocketFailed;
    }

    target_addr = std.mem.zeroes(c.sockaddr_in);
    target_addr.sin_family = c.AF_INET;
    target_addr.sin_port = port;

    const ip_addr = c.inet_addr(host);
    if (ip_addr == c.INADDR_NONE) {
        return error.InvalidIP;
    }
    target_addr.sin_addr.s_addr = ip_addr;

    const conn_result = c.connect(crash_socket, @ptrCast(&target_addr), @sizeOf(c.sockaddr_in));
    if (conn_result < 0) {
        _ = c.net_close(crash_socket);
        crash_socket = -1;
        return error.ConnectionFailed;
    }
}

pub fn handler(exid: c_uint, ctx_ptr: [*c]c.PPCContext) callconv(.c) void {
    const S = struct {
        var in_handler: bool = false;
    };
    if (S.in_handler) {
        std.log.info("Crashed inside of crash handler. Hanging indefinitely", .{});
        while (true) {}
    }
    S.in_handler = true;

    std.log.info("Crash handler triggered, socket={}", .{crash_socket});

    const ctx = if (ctx_ptr) |ctx| ctx.* else {
        std.log.info("Crash handler: no context", .{});
        while (true) {}
    };
    const dump = CrashDump{
        .pc = ctx.pc,
        .exid = exid,
    };

    std.log.info("Sending crash dump, pc=0x{x}, exid={}", .{ dump.pc, dump.exid });

    if (crash_socket >= 0) {
        var retries: u32 = 0;
        var sent: isize = 0;
        while (sent < @sizeOf(CrashDump) and retries < 10) {
            sent = c.send(crash_socket, &dump, @sizeOf(CrashDump), 0);
            if (sent < 0) {
                sent = 0;
                retries += 1;
                var i: u32 = 0;
                while (i < 100000) : (i += 1) {}
            }
        }
        std.log.info("Sent {} bytes after {} retries", .{ sent, retries });
        _ = c.net_close(crash_socket);
        std.log.info("Socket closed", .{});
    } else {
        std.log.info("Invalid socket, not sending", .{});
    }
    while (true) {}
}
