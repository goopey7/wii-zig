const common = @import("common.zig");
const std = @import("std");
const c = @import("platform").c;

/// Wraps libc malloc/free
pub const LibcAllocator = struct {
    const Self = @This();
    const Alignment = std.mem.Alignment;

    stats: common.Stats,

    pub fn init() Self {
        return .{
            .stats = .{
                .total_capacity = 0,
                .current_usage = 0,
                .peak_usage = 0,
                .alloc_count = 0,
                .free_count = 0,
                .alloc_failures = 0,
            },
        };
    }

    pub fn deinit(_: *Self) void {}

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

    fn getArena(_: *anyopaque) common.Arena {
        return .Both;
    }

    pub fn interface(self: *Self) common.Interface {
        return .{
            .ptr = self,
            .vtable = &.{
                .stdInterface = stdInterface,
                .getStats = getStats,
                .getArena = getArena,
                .header_size = 0,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *Self = @ptrCast(@alignCast(ctx));

        if (len == 0) return null;

        const ptr = c.malloc(len) orelse {
            self.stats.alloc_failures += 1;
            return null;
        };
        if (alignment.toByteUnits() > 8) {
            c.free(ptr);
            self.stats.alloc_failures += 1;
            return null;
        }

        self.stats.alloc_count += 1;
        self.stats.last_alloc_pool_consumption = len;
        self.stats.live_requested_bytes += len;
        self.stats.current_usage += len;
        if (self.stats.current_usage > self.stats.peak_usage)
            self.stats.peak_usage = self.stats.current_usage;

        const result: [*]u8 = @ptrCast(ptr);
        return result;
    }

    fn resize(_: *anyopaque, _: []u8, _: Alignment, _: usize, _: usize) bool {
        return false;
    }

    fn remap(_: *anyopaque, _: []u8, _: Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }

    fn free(ctx: *anyopaque, memory: []u8, _: Alignment, _: usize) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        c.free(memory.ptr);
        self.stats.free_count += 1;
        self.stats.current_usage -= memory.len;
        self.stats.live_requested_bytes -= memory.len;
    }
};
