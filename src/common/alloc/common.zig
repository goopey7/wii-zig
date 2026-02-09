const std = @import("std");

pub const Arena = enum {
    MEM_1,
    MEM_2,
};

pub const Stats = struct {
    total_capacity: usize,
    current_usage: usize,
    peak_usage: usize,
    alloc_count: usize,
    free_count: usize,
    alloc_failures: usize,
};

pub const Interface = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        stdInterface: *const fn (*anyopaque) std.mem.Allocator,
        getStats: *const fn (*anyopaque) Stats,
    };

    pub inline fn stdInterface(self: *const Interface) std.mem.Allocator {
        return self.vtable.stdInterface(self.ptr);
    }

    pub inline fn getStats(self: *const Interface) Stats {
        return self.vtable.getStats(self.ptr);
    }
};
