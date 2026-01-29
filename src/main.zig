const std = @import("std");
const c = @cImport({
    @cInclude("gccore.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
    @cInclude("ogc/system.h");
});

pub const std_options = std.Options{
    .logFn = log,
};

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    if (scope == std.log.default_log_scope) {
        _ = c.printf("%s: " ++ format ++ "\n", @tagName(level), args);
    } else {
        _ = c.printf("%s(%s): " ++ format ++ "\n", @tagName(level), @tagName(scope), args);
    }
}

var xfb: ?*anyopaque = undefined;
var rmode: *c.GXRModeObj = undefined;

fn init() void {
    c.VIDEO_Init();

    rmode = c.VIDEO_GetPreferredMode(null);
    xfb = c.MEM_K0_TO_K1(c.SYS_AllocateFramebuffer(rmode).?);

    c.console_init(xfb, 20, 20, rmode.fbWidth, rmode.xfbHeight, rmode.fbWidth * 2);

    c.VIDEO_Configure(rmode);
    c.VIDEO_SetNextFramebuffer(xfb);
    c.VIDEO_SetBlack(false);
    c.VIDEO_Flush();
    c.VIDEO_WaitVSync();
    if ((rmode.viTVMode & c.VI_NON_INTERLACE) != 0) {
        c.VIDEO_WaitVSync();
    }
}

export fn main() c_int {
    init();
    std.log.info("Hello from zig!", .{});
    std.log.info("Right now I gotta do work that solves my research question", .{});
    std.log.info("enough messing around", .{});
    while (true) {
        c.VIDEO_WaitVSync();
    }

    return 0;
}
