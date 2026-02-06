const std = @import("std");
const allocator = @import("allocator.zig");
pub const log = @import("log.zig").log;
pub const c = @import("platform.zig").c;

pub fn entry() !void {
    {
        var alloc = allocator.BumpAllocator.init(.MEM_1);
        defer alloc.deinit();
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

    {
        var alloc = allocator.GeneralPurposeAllocator.init(.MEM_1);
        defer alloc.deinit();
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
}
