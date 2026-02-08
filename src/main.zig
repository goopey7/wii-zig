const std = @import("std");
const log = @import("platform").log;
const c = @import("platform").c;
const bench = @import("benchmark");

pub const std_options = std.Options{
    .logFn = log,
};

fn init() void {
    c.VIDEO_Init();
    _ = c.consoleInit(null);
}

fn entry() !void {
    try bench.main();
}

export fn main() c_int {
    init();

    entry() catch |err| {
        std.log.err("{}", .{err});
    };

    return 0;
}
