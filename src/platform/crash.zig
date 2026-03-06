const http = @import("http.zig");
const c = @import("platform.zig").c;
const std = @import("std");

const CRASH_MAGIC: u32 = 0xDEADC0DE;
const crash_dump_addr: *volatile CrashDump = @ptrFromInt(0x80000060);

pub const CrashDump = struct {
    magic: u32,
    pc: u32,
    exid: u32,
};

pub fn checkForPendingCrash() !void {
    if (crash_dump_addr.magic != CRASH_MAGIC) {
        return;
    }

    crash_dump_addr.magic = 0;
    const dump = crash_dump_addr.*;
    std.log.warn("Previous session crashed! PC={} exid={}", .{
        dump.pc, dump.exid,
    });

    const response = try http.post("http://wiicrash.samcollier.dev", 80, std.mem.asBytes(&dump));
    std.log.info("response status: {}", .{@intFromEnum(response.status)});
    if (response.body) |body| {
        std.log.info("response body: {}", .{body});
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

    std.log.debug("crash!", .{});
    S.in_handler = true;
    const ctx = if (ctx_ptr) |ctx| ctx.* else return;
    crash_dump_addr.* = CrashDump{
        .magic = CRASH_MAGIC,
        .pc = ctx.pc,
        .exid = exid,
    };

    c.SYS_ResetSystem(c.SYS_HOTRESET, 0, 0);

    //std.log.debug("making req", .{});
    //const response = http.post("http://wiicrash.samcollier.dev", 80, std.mem.asBytes(&dump));
    //std.log.debug("req complete", .{});
    //if (response) |res| {
    //    std.log.info("response status: {}", .{@intFromEnum(res.status)});
    //    if (res.body) |body| {
    //        std.log.info("response body: {}", .{body});
    //    }
    //} else |err| {
    //    std.log.err("error: {}", .{err});
    //}
}
