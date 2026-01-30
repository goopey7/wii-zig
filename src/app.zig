const std = @import("std");
const allocator = @import("allocator.zig");
const c = @import("main.zig").c;
const log = @import("log.zig");

pub fn entry() !void {
    std.log.info("hello world!", .{});
    return error.Whoops;
}
