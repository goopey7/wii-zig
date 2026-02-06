const std = @import("std");
const app = @import("common/app.zig");
const log = @import("platform").log;

pub const std_options = std.Options{
    .logFn = log,
};

fn init() void {
    app.c.VIDEO_Init();
    _ = app.c.consoleInit(null);
}

export fn main() c_int {
    init();

    app.entry() catch |err| {
        std.log.err("{}", .{err});
    };

    return 0;
}
