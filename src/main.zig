const std = @import("std");
pub const c = @cImport({
    @cInclude("gccore.h");
    @cInclude("ogc/system.h");
    @cInclude("stdio.h");
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
        _ = std.c.printf("%s: ", @tagName(level).ptr);
    } else {
        _ = std.c.printf("%s(%s): ", @tagName(level).ptr, @tagName(scope).ptr);
    }

    const ArgsType = @TypeOf(args);
    const args_type_info = @typeInfo(ArgsType);

    if (args_type_info != .@"struct") {
        @compileError("args must be a tuple");
    }

    comptime var arg_index = 0;
    comptime var i = 0;

    inline while (i < format.len) : (i += 1) {
        if (format[i] == '{' and i + 1 < format.len and format[i + 1] == '}') {
            const fields = args_type_info.@"struct".fields;
            if (arg_index < fields.len) {
                const value = @field(args, fields[arg_index].name);
                printValue(value);
                arg_index += 1;
            }
            i += 1;
        } else {
            _ = c.putchar(format[i]);
        }
    }

    _ = c.putchar('\n');
}

fn printValue(value: anytype) void {
    const T = @TypeOf(value);

    switch (@typeInfo(T)) {
        .int => {
            if (@typeInfo(T).int.signedness == .signed) {
                _ = std.c.printf("%lld", @as(c_longlong, value));
            } else {
                _ = std.c.printf("%llu", @as(c_ulonglong, value));
            }
        },
        .float => _ = std.c.printf("%f", @as(f64, value)),
        .bool => _ = std.c.printf("%s", if (value) "true".ptr else "false".ptr),
        .error_set => {
            _ = std.c.printf("%s", @errorName(value).ptr);
        },
        else => @compileError("Unable to print value"),
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
