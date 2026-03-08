const std = @import("std");
const log = @import("platform").log;
const c = @import("platform").c;
const wpad = @import("platform").wpad;
const bench = @import("benchmark");
const crash = @import("platform").crash;
const platform = @import("platform");

pub const std_options = std.Options{
    .logFn = log,
};

fn init() !void {
    c.PPCExcptCurPanicFn = crash.handler;
    c.VIDEO_Init();
    _ = wpad.WPAD_Init();
    _ = c.consoleInit(null);
    var local_ip: [16]u8 = std.mem.zeroes([16]u8);
    var netmask: [16]u8 = std.mem.zeroes([16]u8);
    var gateway: [16]u8 = std.mem.zeroes([16]u8);
    const ret = c.if_config(&local_ip, &netmask, &gateway, true, 20);
    if (ret < 0) {
        return error.InitNetworkFailed;
    }
    const net_log = std.log.scoped(.Network);
    net_log.info("local ip: {}", .{local_ip});
    net_log.info("netmask: {}", .{netmask});
    net_log.info("gateway: {}", .{gateway});
    try crash.init();
}

fn entry() !void {
    const ptr: *volatile u32 = @ptrFromInt(8);
    ptr.* = 0xDEADC0DE;
    try bench.main();
}

export fn main() c_int {
    init() catch |err| {
        std.log.err("{}", .{err});
    };

    entry() catch |err| {
        std.log.err("{}", .{err});
    };

    while (c.SYS_MainLoop()) {
        _ = wpad.WPAD_ScanPads();
        if ((wpad.WPAD_ButtonsDown(0) & wpad.WPAD_BUTTON_HOME) > 0) {
            c.exit(0);
        }
    }

    return 0;
}
