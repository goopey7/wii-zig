const std = @import("std");
const app = @import("app.zig");
pub const log = @import("log.zig").log;
pub const c = @cImport({
    @cInclude("gccore.h");
    @cInclude("ogc/system.h");
    @cInclude("stdio.h");
});

pub const std_options = std.Options{
    .logFn = log,
};

fn init() void {
    c.VIDEO_Init();
    _ = c.consoleInit(null);
}

export fn main() c_int {
    init();

    app.entry() catch |err| {
        std.log.err("{}", .{err});
    };

    return 0;
}
