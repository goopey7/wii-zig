const std = @import("std");
const log = @import("platform").log;
const c = @import("platform").c;
const wpad = @import("platform").wpad;
const bench = @import("benchmark");
const crash = @import("platform").crash;
const platform = @import("platform");
const tracy = @import("common").tracy;

pub const std_options = std.Options{
    .logFn = log,
};

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    _ = ret_addr;
    crash.sendPanic(msg, error_return_trace);
}

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
    tracy.startup();
}

const MenuItem = enum { benchmark, crash, exit };

fn drawMenu(selected: MenuItem) void {
    _ = c.printf("\x1b[2J\x1b[H");
    _ = c.printf("\n  === Main Menu ===\n\n");
    _ = c.printf("%s %sRun Benchmark\x1b[0m\n", @as([*c]const u8, if (selected == .benchmark) ">" else " "), @as([*c]const u8, if (selected == .benchmark) "\x1b[33m" else ""));
    _ = c.printf("%s %sTrigger Crash\x1b[0m\n", @as([*c]const u8, if (selected == .crash) ">" else " "), @as([*c]const u8, if (selected == .crash) "\x1b[33m" else ""));
    _ = c.printf("%s %sExit\x1b[0m\n", @as([*c]const u8, if (selected == .exit) ">" else " "), @as([*c]const u8, if (selected == .exit) "\x1b[33m" else ""));
    _ = c.printf("\n  DPad up/down to navigate, A to select\n");
}

fn entry() !void {
    const items = [_]MenuItem{ .benchmark, .crash, .exit };
    var index: usize = 0;

    drawMenu(items[index]);

    while (c.SYS_MainLoop()) {
        _ = wpad.WPAD_ScanPads();
        const pressed = wpad.WPAD_ButtonsDown(0);

        if ((pressed & wpad.WPAD_BUTTON_DOWN) > 0) {
            if (index + 1 < items.len) index += 1;
            drawMenu(items[index]);
        } else if ((pressed & wpad.WPAD_BUTTON_UP) > 0) {
            if (index > 0) index -= 1;
            drawMenu(items[index]);
        } else if ((pressed & wpad.WPAD_BUTTON_A) > 0) {
            switch (items[index]) {
                .benchmark => try bench.main(),
                .crash => platform.crash_scenarios.deep_chain(),
                .exit => c.exit(0),
            }
            drawMenu(items[index]);
        } else if ((pressed & wpad.WPAD_BUTTON_HOME) > 0) {
            c.exit(0);
        }
    }
}

export fn main() c_int {
    // wanna avoid as many abstractions as possible. Just wanna grab the stack ptr immediately.
    // hence inline asm
    crash.stack_top = asm volatile ("mr %[out], 1"
        : [out] "=r" (-> u32),
    );
    // align up to nearest 4k aligned addr (seems to work for the stack)
    crash.stack_top = std.mem.alignForward(u32, crash.stack_top, 0x1000);

    init() catch |err| {
        @panic(@errorName(err));
    };

    entry() catch |err| {
        @panic(@errorName(err));
    };

    while (c.SYS_MainLoop()) {
        _ = wpad.WPAD_ScanPads();
        if ((wpad.WPAD_ButtonsDown(0) & wpad.WPAD_BUTTON_HOME) > 0) {
            c.exit(0);
        }
    }

    tracy.shutdown();
    c.exit(0);
    return 0;
}
