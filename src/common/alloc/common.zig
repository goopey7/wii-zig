const std = @import("std");

/// wraps an existing allocator, and triggers a panic when OOM
/// panic is defined in main.zig. It sends a stacktrace over TCP
pub const PanicAllocator = struct {
    inner: std.mem.Allocator,
    const Alignment = std.mem.Alignment;

    pub fn allocator(self: *PanicAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, n: usize, alignment: Alignment, ra: usize) ?[*]u8 {
        const self: *PanicAllocator = @ptrCast(@alignCast(ctx));
        return self.inner.rawAlloc(n, alignment, ra) orelse @panic("PanicAllocator OOM");
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: Alignment, new_len: usize, ra: usize) bool {
        const self: *PanicAllocator = @ptrCast(@alignCast(ctx));
        return self.inner.rawResize(buf, alignment, new_len, ra);
    }

    fn remap(ctx: *anyopaque, buf: []u8, alignment: Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *PanicAllocator = @ptrCast(@alignCast(ctx));
        return self.inner.rawRemap(buf, alignment, new_len, ra);
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: Alignment, ra: usize) void {
        const self: *PanicAllocator = @ptrCast(@alignCast(ctx));
        self.inner.rawFree(buf, alignment, ra);
    }
};

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
    largest_free_block: usize = 0,
    total_free: usize = 0,
    last_alloc_pool_consumption: usize = 0,
    total_header_overhead: usize = 0,
    peak_header_overhead: usize = 0,
    fixed_overhead: usize = 0,
    live_requested_bytes: usize = 0,
};

pub const Interface = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        stdInterface: *const fn (*anyopaque) std.mem.Allocator,
        getStats: *const fn (*anyopaque) Stats,
        getArena: *const fn (*anyopaque) Arena,
        header_size: usize,
    };

    pub inline fn stdInterface(self: *const Interface) std.mem.Allocator {
        return self.vtable.stdInterface(self.ptr);
    }

    pub inline fn getStats(self: *const Interface) Stats {
        return self.vtable.getStats(self.ptr);
    }

    pub inline fn getArena(self: *const Interface) Arena {
        return self.vtable.getArena(self.ptr);
    }

    pub inline fn headerSize(self: *const Interface) usize {
        return self.vtable.header_size;
    }
};
