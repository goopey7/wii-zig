const common = @import("common.zig");
const std = @import("std");
const c = @import("platform").c;

pub const BumpAllocator = struct {
    const Self = @This();
    const Alignment = std.mem.Alignment;

    arena: common.Arena,
    ptr: [*]u8,
    start: [*]u8,
    end: [*]u8,
    stats: common.Stats,

    /// pass a null size to occupy all remaining memory in the arena
    pub fn init(arena: common.Arena, size: ?usize) !Self {
        const lo = switch (arena) {
            .MEM_1 => c.SYS_GetArena1Lo(),
            .MEM_2 => c.SYS_GetArena2Lo(),
        };
        const hi = switch (arena) {
            .MEM_1 => c.SYS_GetArena1Hi(),
            .MEM_2 => c.SYS_GetArena2Hi(),
        };

        if (size) |sz| {
            if (@intFromPtr(hi) - @intFromPtr(lo) < sz)
                return error.OutOfMemory;
            const new_lo: *anyopaque = @ptrFromInt(@intFromPtr(lo) + sz);
            switch (arena) {
                .MEM_1 => c.SYS_SetArena1Lo(new_lo),
                .MEM_2 => c.SYS_SetArena2Lo(new_lo),
            }
            return .{
                .arena = arena,
                .start = @ptrCast(lo),
                .ptr = @ptrCast(lo),
                .end = @ptrCast(new_lo),
                .stats = .{
                    .total_capacity = sz,
                    .alloc_count = 0,
                    .alloc_failures = 0,
                    .current_usage = 0,
                    .free_count = 0,
                    .peak_usage = 0,
                },
            };
        } else {
            switch (arena) {
                .MEM_1 => c.SYS_SetArena1Lo(hi),
                .MEM_2 => c.SYS_SetArena2Lo(hi),
            }
            const total_capacity = @intFromPtr(hi) - @intFromPtr(lo);
            return .{
                .arena = arena,
                .start = @ptrCast(lo),
                .ptr = @ptrCast(lo),
                .end = @ptrCast(hi),
                .stats = .{
                    .total_capacity = total_capacity,
                    .alloc_count = 0,
                    .alloc_failures = 0,
                    .current_usage = 0,
                    .free_count = 0,
                    .peak_usage = 0,
                },
            };
        }
    }

    pub fn reset(self: *Self) void {
        self.ptr = self.start;
    }

    pub fn deinit(self: *Self) void {
        switch (self.arena) {
            .MEM_1 => c.SYS_SetArena1Lo(self.start),
            .MEM_2 => c.SYS_SetArena2Lo(self.start),
        }
    }

    fn stdInterface(ctx: *anyopaque) std.mem.Allocator {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn getStats(ctx: *anyopaque) common.Stats {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.stats;
    }

    fn getArena(ctx: *anyopaque) common.Arena {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.arena;
    }

    fn dumpStats(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const log = std.log.scoped(.BumpAllocator);
        log.info("Allocator stats", .{});
        log.info("  Capacity:            {} KB", .{self.stats.total_capacity / 1024});
        log.info("  Used:                {} KB", .{self.stats.current_usage / 1024});
        log.info("  Peak:                {} KB", .{self.stats.peak_usage / 1024});
        log.info("  Free:                {} KB", .{(self.stats.total_capacity - self.stats.current_usage) / 1024});
        log.info("  Largest Free Block:  {} KB", .{(self.stats.total_capacity - self.stats.current_usage) / 1024});
        log.info("  Allocs:              {}", .{self.stats.alloc_count});
        log.info("  Frees:               {}", .{self.stats.free_count});
        log.info("  Failures:            {}", .{self.stats.alloc_failures});
    }

    pub fn interface(self: *Self) common.Interface {
        return .{
            .ptr = self,
            .vtable = &.{
                .stdInterface = stdInterface,
                .getStats = getStats,
                .getArena = getArena,
                .dumpStats = dumpStats,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *Self = @ptrCast(@alignCast(ctx));

        if (len == 0) return null;

        var p = @intFromPtr(self.ptr);
        p = std.mem.alignForward(u32, p, alignment.toByteUnits());

        const new_p = p + len;
        if (new_p > @intFromPtr(self.end)) {
            self.stats.alloc_failures += 1;
            return null;
        }

        self.ptr = @ptrFromInt(new_p);
        self.stats.current_usage += len;
        self.stats.alloc_count += 1;
        if (self.stats.current_usage > self.stats.peak_usage) {
            self.stats.peak_usage = self.stats.current_usage;
        }
        return @ptrFromInt(p);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        _ = ctx;
        _ = memory;
        _ = alignment;
        _ = ret_addr;
        _ = new_len;
        return false;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        _ = ctx;
        _ = memory;
        _ = alignment;
        _ = ret_addr;
        _ = new_len;
        return null;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        _ = ctx;
        _ = memory;
        _ = alignment;
        _ = ret_addr;
    }
};

test "full allocator init and deinit" {
    var allocator = try BumpAllocator.init(.MEM_2, 1024 * 256);
    defer allocator.deinit();
    if (allocator.stats.total_capacity == 0 or allocator.stats.alloc_count != 0) return error.InitFail;
}

test "basic alloc" {
    var allocator = try BumpAllocator.init(.MEM_2, 1024 * 256);
    defer allocator.deinit();
    const alloc = allocator.interface().stdInterface();
    _ = alloc.rawAlloc(64, .@"1", @returnAddress()) orelse return error.AllocFail;
    if (allocator.stats.alloc_count != 1) return error.AllocCount;
    if (allocator.stats.current_usage < 64) return error.UsageLow;
}

test "multiple allocations" {
    var allocator = try BumpAllocator.init(.MEM_2, 1024 * 512);
    defer allocator.deinit();
    const alloc = allocator.interface().stdInterface();
    _ = alloc.rawAlloc(32, .@"1", @returnAddress()) orelse return error.A1;
    _ = alloc.rawAlloc(64, .@"1", @returnAddress()) orelse return error.A2;
    _ = alloc.rawAlloc(128, .@"1", @returnAddress()) orelse return error.A3;
    if (allocator.stats.alloc_count != 3) return error.Count3;
}

test "alignment handling" {
    var allocator = try BumpAllocator.init(.MEM_2, 1024 * 256);
    defer allocator.deinit();
    const alloc = allocator.interface().stdInterface();
    const ptr = alloc.rawAlloc(17, .@"8", @returnAddress()) orelse return error.AlignAlloc;
    if (@intFromPtr(ptr) % 8 != 0) return error.NotAligned;
}

test "zero size alloc" {
    var allocator = try BumpAllocator.init(.MEM_2, 1024 * 256);
    defer allocator.deinit();
    const alloc = allocator.interface().stdInterface();
    const ptr = alloc.rawAlloc(0, .@"1", @returnAddress());
    if (ptr != null or allocator.stats.alloc_count != 0) return error.ZeroAlloc;
}

test "out of memory" {
    var allocator = try BumpAllocator.init(.MEM_2, 256);
    defer allocator.deinit();
    const alloc = allocator.interface().stdInterface();
    const result = alloc.rawAlloc(1024 * 200, .@"1", @returnAddress());
    if (result != null) return error.ShouldFail;
    if (allocator.stats.alloc_failures == 0) return error.NoFail;
}
