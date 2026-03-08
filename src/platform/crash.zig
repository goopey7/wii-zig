const http = @import("http.zig");
const c = @import("platform.zig").c;
const dolphin = @import("dolphin.zig");
const std = @import("std");

pub const CRASH_DUMP_HOST_DOLPHIN = "127.0.0.1";
pub const CRASH_DUMP_PORT_DOLPHIN: u16 = 9000;

pub const CRASH_DUMP_HOST = "192.168.0.8";
pub const CRASH_DUMP_PORT: u16 = 9000;

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
    crash_socket = c.socket(c.AF_INET, c.SOCK_DGRAM, 0);
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

    std.log.debug("crash!", .{});
    const ctx = if (ctx_ptr) |ctx| ctx.* else return;
    const dump = CrashDump{
        .pc = ctx.pc,
        .exid = exid,
    };
    std.log.debug("pc: 0x{x}", .{dump.pc});
    std.log.debug("exid: {x}", .{dump.exid});

    if (crash_socket >= 0) {
        _ = c.sendto(crash_socket, &dump, @sizeOf(CrashDump), 0, @ptrCast(&target_addr), @sizeOf(c.sockaddr_in));
    }
    while (true) {}
}
