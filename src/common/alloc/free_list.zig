const std = @import("std");
const common = @import("common.zig");
const c = @import("platform").c;

const BlockHeader = struct {
    size: usize,
    next: ?*BlockHeader,
    free: bool,
};

const MIN_SPLIT_SIZE = @sizeOf(BlockHeader) + @alignOf(BlockHeader) + 16;

pub const FreeListAllocator = struct {
    const Self = @This();
    const Alignment = std.mem.Alignment;

    arena: common.Arena,
    start: [*]u8,
    end: [*]u8,
    free_list: ?*BlockHeader,
    stats: common.Stats,

    pub fn init(arena: common.Arena, size: ?usize) !Self {
        _ = size;
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

        const header: *BlockHeader = @ptrCast(@alignCast(lo));
        header.* = .{
            .size = total_capacity - @sizeOf(BlockHeader),
            .next = null,
            .free = true,
        };

        return .{
            .arena = arena,
            .start = @ptrCast(lo),
            .end = @ptrCast(hi),
            .free_list = header,
            .stats = .{
                .total_capacity = total_capacity,
                .current_usage = 0,
                .peak_usage = 0,
                .alloc_count = 0,
                .free_count = 0,
                .alloc_failures = 0,
            },
        };
    }

    pub fn deinit(self: *FreeListAllocator) void {
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
        _ = self;
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

        var prev: ?*BlockHeader = null;
        var current = self.free_list;

        while (current) |block| {
            const header_addr = @intFromPtr(block);

            const backref_size = @sizeOf(usize);
            const min_payload_addr = header_addr + @sizeOf(BlockHeader) + backref_size;
            const actual_payload = std.mem.alignForward(usize, min_payload_addr, alignment.toByteUnits());
            const padding = actual_payload - header_addr - @sizeOf(BlockHeader);

            const total_needed = padding + len;

            if (block.size >= total_needed) {
                const remaining = block.size - total_needed;

                const backref_ptr: *usize = @ptrFromInt(actual_payload - backref_size);
                backref_ptr.* = header_addr;

                if (remaining > MIN_SPLIT_SIZE) {
                    const next_header_addr = actual_payload + len;
                    const aligned_next_header = std.mem.alignForward(usize, next_header_addr, @alignOf(BlockHeader));
                    const alignment_padding = aligned_next_header - next_header_addr;

                    const new_block: *BlockHeader = @ptrFromInt(aligned_next_header);
                    new_block.* = .{
                        .size = remaining - @sizeOf(BlockHeader) - alignment_padding,
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
                block.size = total_needed;
                self.stats.alloc_count += 1;
                self.stats.current_usage += block.size;
                if (self.stats.current_usage > self.stats.peak_usage) {
                    self.stats.peak_usage = self.stats.current_usage;
                }
                return @ptrFromInt(actual_payload);
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

        const mem_addr = @intFromPtr(memory.ptr);

        const backref_ptr: *const usize = @ptrFromInt(mem_addr - @sizeOf(usize));
        const header_addr = backref_ptr.*;

        if (header_addr < @intFromPtr(self.start) or header_addr >= @intFromPtr(self.end)) {
            std.log.err("free: INVALID HEADER ADDR {} (valid: {}-{})", .{ header_addr, @intFromPtr(self.start), @intFromPtr(self.end) });
            return;
        }

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

        // Coalesce with next block
        if (block.next) |next| {
            const block_end = header_addr + @sizeOf(BlockHeader) + block.size;
            if (block_end == @intFromPtr(next)) {
                block.size += @sizeOf(BlockHeader) + next.size;
                block.next = next.next;
            }
        }

        // Coalesce with prev block
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
};

test "full allocator init and deinit" {
    var allocator = try FreeListAllocator.init(.MEM_2, 1024 * 256);
    defer allocator.deinit();
    if (allocator.stats.total_capacity == 0 or allocator.stats.alloc_count != 0) return error.InitFail;
}

test "basic alloc free" {
    var allocator = try FreeListAllocator.init(.MEM_2, 1024 * 256);
    defer allocator.deinit();
    const alloc = allocator.interface().stdInterface();
    const ptr = alloc.rawAlloc(64, .@"1", @returnAddress()) orelse return error.AllocFail;
    if (allocator.stats.alloc_count != 1) return error.AllocCount;
    if (allocator.stats.current_usage < 64) return error.UsageLow;
    alloc.rawFree(ptr[0..64], .@"1", @returnAddress());
    if (allocator.stats.free_count != 1) return error.FreeCount;
}

test "multiple allocations" {
    var allocator = try FreeListAllocator.init(.MEM_2, 1024 * 512);
    defer allocator.deinit();
    const alloc = allocator.interface().stdInterface();
    const p1 = alloc.rawAlloc(32, .@"1", @returnAddress()) orelse return error.A1;
    const p2 = alloc.rawAlloc(64, .@"1", @returnAddress()) orelse return error.A2;
    const p3 = alloc.rawAlloc(128, .@"1", @returnAddress()) orelse return error.A3;
    if (allocator.stats.alloc_count != 3) return error.Count3;
    alloc.rawFree(p1[0..32], .@"1", @returnAddress());
    alloc.rawFree(p2[0..64], .@"1", @returnAddress());
    alloc.rawFree(p3[0..128], .@"1", @returnAddress());
    if (allocator.stats.free_count != 3) return error.Count3Free;
}

test "reallocate after free" {
    var allocator = try FreeListAllocator.init(.MEM_2, 1024 * 256);
    defer allocator.deinit();
    const alloc = allocator.interface().stdInterface();
    const p1 = alloc.rawAlloc(64, .@"1", @returnAddress()) orelse return error.A1;
    alloc.rawFree(p1[0..64], .@"1", @returnAddress());
    const p2 = alloc.rawAlloc(64, .@"1", @returnAddress()) orelse return error.A2;
    alloc.rawFree(p2[0..64], .@"1", @returnAddress());
    if (allocator.stats.alloc_count != 2 or allocator.stats.free_count != 2) return error.Realloc;
}

test "alignment handling" {
    var allocator = try FreeListAllocator.init(.MEM_2, 1024 * 256);
    defer allocator.deinit();
    const alloc = allocator.interface().stdInterface();
    const ptr = alloc.rawAlloc(17, .@"8", @returnAddress()) orelse return error.AlignAlloc;
    if (@intFromPtr(ptr) % 8 != 0) return error.NotAligned;
}
