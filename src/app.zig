const std = @import("std");
const allocator = @import("allocator.zig");
const c = @import("main.zig").c;
const log = @import("log.zig");

pub fn entry() !void {
    var alloc = allocator.GeneralPurposeAllocator.init(.MEM_1);
    var list = try std.ArrayList(std.ArrayList(u8)).initCapacity(alloc.interface(), 10);
    for (0..11) |_| {
        const arr = try std.ArrayList(u8).initCapacity(alloc.interface(), 1024 * 1024 * 2);
        try list.append(alloc.interface(), arr);
    }

    for (list.items, 0..) |*a, idx| {
        if (idx % 2 == 0) {
            a.deinit(alloc.interface());
        }
    }
    alloc.dumpStats();
}
