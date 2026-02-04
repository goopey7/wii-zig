const std = @import("std");
const c = @import("root").c;
const common = @import("common.zig");

const BlockHeader = struct {
    size: usize,
    next: ?*BlockHeader,
    free: bool,
};

pub const GeneralPurposeAllocator = struct {
    const Self = @This();
    const Alignment = std.mem.Alignment;

    arena: common.Arena,
    start: [*]u8,
    end: [*]u8,
    free_list: ?*BlockHeader,
    stats: common.Stats,

    pub fn init(arena: common.Arena) Self {
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

        const size = @intFromPtr(hi) - @intFromPtr(lo);

        const header: *BlockHeader = @ptrCast(@alignCast(lo));
        header.* = .{
            .size = size - @sizeOf(BlockHeader),
            .next = null,
            .free = true,
        };

        return .{
            .arena = arena,
            .start = @ptrCast(lo),
            .end = @ptrCast(hi),
            .free_list = header,
            .stats = .{
                .total_capacity = size,
                .current_usage = 0,
                .peak_usage = 0,
                .alloc_count = 0,
                .free_count = 0,
                .alloc_failures = 0,
            },
        };
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

        var prev: ?*BlockHeader = null;
        var current = self.free_list;

        while (current) |block| {
            const header_addr = @intFromPtr(block);
            const payload_addr = header_addr + @sizeOf(BlockHeader);
            const aligned_payload = std.mem.alignForward(usize, payload_addr, alignment.toByteUnits());

            const padding = aligned_payload - payload_addr;
            const total_needed = padding + len;

            if (block.size >= total_needed) {
                const remaining = block.size - total_needed;

                if (remaining > @sizeOf(BlockHeader)) {
                    const next_header_addr = aligned_payload + len;
                    const new_block: *BlockHeader = @ptrFromInt(next_header_addr);
                    new_block.* = .{
                        .size = remaining - @sizeOf(BlockHeader),
                        .next = block.next,
                        .free = true,
                    };

                    if (prev) |p| {
                        p.next = new_block;
                    } else {
                        self.free_list = new_block;
                    }
                } else {
                    if (prev) |p| {
                        p.next = block.next;
                    } else {
                        self.free_list = block.next;
                    }
                }
                block.free = false;
                block.size = len;
                self.stats.alloc_count += 1;
                self.stats.current_usage += len;
                if (self.stats.current_usage > self.stats.peak_usage) {
                    self.stats.peak_usage = self.stats.current_usage;
                }
                return @ptrFromInt(aligned_payload);
            }

            prev = block;
            current = block.next;
        }
        self.stats.alloc_failures += 1;
        return null;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        _ = alignment;
        _ = ret_addr;
        const self: *Self = @ptrCast(@alignCast(ctx));
        const header_addr = @intFromPtr(memory.ptr) - @sizeOf(BlockHeader);

        const block: *BlockHeader = @ptrFromInt(header_addr);
        block.free = true;
        self.stats.free_count += 1;
        self.stats.current_usage -= block.size;

        var prev: ?*BlockHeader = null;
        var current = self.free_list;

        while (current) |current_block| {
            if (@intFromPtr(current_block) > header_addr) {
                break;
            }
            prev = current_block;
            current = current_block.next;
        }

        block.next = current;
        if (prev) |p| {
            p.next = block;
        } else {
            self.free_list = block;
        }

        if (block.next) |next| {
            const block_end = header_addr + @sizeOf(BlockHeader) + block.size;
            if (block_end == @intFromPtr(next)) {
                block.size += @sizeOf(BlockHeader) + next.size;
                block.next = next.next;
            }
        }

        if (prev) |p| {
            const prev_end = @intFromPtr(p) + @sizeOf(BlockHeader) + p.size;
            if (prev_end == header_addr) {
                p.size += @sizeOf(BlockHeader) + block.size;
                p.next = block.next;
            }
        }
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

    pub fn largestFreeBlock(self: *const GeneralPurposeAllocator) u32 {
        var max: usize = 0;
        var current = self.free_list;

        while (current) |block| {
            if (block.size > max) {
                max = block.size;
            }
            current = block.next;
        }

        return max;
    }

    pub fn totalFreeMemory(self: *const GeneralPurposeAllocator) u32 {
        var total: usize = 0;
        var current = self.free_list;

        while (current) |block| {
            total += block.size;
            current = block.next;
        }

        return total;
    }

    pub fn fragmentation(self: *const GeneralPurposeAllocator) f32 {
        return 1.0 - @as(f32, @floatFromInt(self.largestFreeBlock())) / @as(f32, @floatFromInt(self.totalFreeMemory()));
    }

    pub fn dumpStats(self: *const GeneralPurposeAllocator) void {
        const log = std.log.scoped(.GeneralPurposeAllocator);
        log.info("Allocator stats", .{});
        log.info("  Capacity:            {} KB", .{self.stats.total_capacity / 1024});
        log.info("  Used:                {} KB", .{self.stats.current_usage / 1024});
        log.info("  Peak:                {} KB", .{self.stats.peak_usage / 1024});
        log.info("  Free:                {} KB", .{self.totalFreeMemory() / 1024});
        log.info("  Largest Free Block:  {} KB", .{self.largestFreeBlock() / 1024});
        log.info("  Allocs:              {}", .{self.stats.alloc_count});
        log.info("  Frees:               {}", .{self.stats.free_count});
        log.info("  Failures:            {}", .{self.stats.alloc_failures});
        log.info("  Fragmentation:       {}", .{self.fragmentation()});
    }
};
