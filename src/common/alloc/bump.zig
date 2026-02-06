const Arena = @import("common.zig").Arena;
const Stats = @import("common.zig").Stats;
const std = @import("std");
const c = @import("common.zig").c;

pub const BumpAllocator = struct {
    const Self = @This();
    const Alignment = std.mem.Alignment;

    arena: Arena,
    ptr: [*]u8,
    start: [*]u8,
    end: [*]u8,
    stats: Stats,

    pub fn init(arena: Arena) Self {
        const lo = switch (arena) {
            .MEM_1 => c.SYS_GetArena1Lo(),
            .MEM_2 => c.SYS_GetArena2Lo(),
        };
        const hi = switch (arena) {
            .MEM_1 => c.SYS_GetArena1Hi(),
            .MEM_2 => c.SYS_GetArena2Hi(),
        };

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

    pub fn reset(self: *Self) void {
        self.ptr = self.start;
    }

    pub fn deinit(self: *Self) void {
        switch (self.arena) {
            .MEM_1 => c.SYS_SetArena1Lo(self.start),
            .MEM_2 => c.SYS_SetArena2Lo(self.start),
        }
    }

    pub fn interface(self: *Self) std.mem.Allocator {
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

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *Self = @ptrCast(@alignCast(ctx));

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

    pub fn fragmentation(self: *const BumpAllocator) f32 {
        const largest_free_block = self.stats.total_capacity - self.stats.current_usage;
        const total_free_memory = largest_free_block;

        return 1.0 - @as(f32, @floatFromInt(largest_free_block)) / @as(f32, @floatFromInt(total_free_memory));
    }

    pub fn dumpStats(self: *const BumpAllocator) void {
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
        log.info("  Fragmentation:       {}", .{self.fragmentation()});
    }
};
