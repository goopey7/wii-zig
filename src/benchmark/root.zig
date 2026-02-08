const std = @import("std");
const alloc = @import("common").allocator;

pub fn main() !void {
    var a = alloc.GeneralPurposeAllocator.init(.MEM_1);
    defer a.deinit();
    std.log.info("bench!", .{});
}
