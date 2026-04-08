const std = @import("std");
const common = @import("common.zig");
const c = @import("platform").c;

const LINEAR: u8 = 7;
const SUB_BIN: u8 = 5;
const BIN_COUNT: u32 = 64 - LINEAR;
const SUB_BIN_COUNT: u32 = 1 << SUB_BIN;
const MIN_ALLOC_SIZE: u32 = 1 << LINEAR;
const BLOCK_COUNT: u32 = ((BIN_COUNT - 1) * SUB_BIN_COUNT) + 1;
const MIN_ALIGNMENT: u8 = LINEAR - SUB_BIN;

const Arena = common.Arena;

const Block = struct {
    offset: usize,
    size: usize,
    next_free: ?*Block = null,
    prev_free: ?*Block = null,
    next_physical: ?*Block = null,
    prev_physical: ?*Block = null,

    inline fn isFree(self: *const Block) bool {
        return self.prev_free != self;
    }

    inline fn markUsed(self: *Block) void {
        self.prev_free = self;
        self.next_free = null;
    }

    inline fn markFree(self: *Block) void {
        self.prev_free = null;
        self.next_free = null;
    }
};

const BlockMap = struct {
    bin_idx: u32,
    sub_bin_idx: u32,
    rounded_size: usize,
    idx: u32,
};

pub const TlsfAllocator = struct {
    const Self = @This();
    const Alignment = std.mem.Alignment;

    arena: Arena,
    start: [*]u8,
    end: [*]u8,
    blocks: [BLOCK_COUNT]?*Block,
    bin_bitmap: u32 = 0,
    sub_bin_bitmap: [BIN_COUNT]u32 = [_]u32{0} ** BIN_COUNT,
    first_block: ?*Block = null,
    stats: common.Stats,

    pub fn init(arena: Arena, capacity: ?usize) !Self {
        const lo = switch (arena) {
            .MEM_1 => c.SYS_GetArena1Lo(),
            .MEM_2 => c.SYS_GetArena2Lo(),
        };
        const hi = switch (arena) {
            .MEM_1 => c.SYS_GetArena1Hi(),
            .MEM_2 => c.SYS_GetArena2Hi(),
        };

        var total_capacity = @intFromPtr(hi) - @intFromPtr(lo);

        if (capacity) |cap| {
            if (cap >= total_capacity) return error.CapacityTooLarge;
            total_capacity = cap;
        }

        switch (arena) {
            .MEM_1 => c.SYS_SetArena1Lo(@ptrFromInt(@intFromPtr(lo) + total_capacity)),
            .MEM_2 => c.SYS_SetArena2Lo(@ptrFromInt(@intFromPtr(lo) + total_capacity)),
        }

        const block: *Block = @ptrCast(@alignCast(lo));
        block.* = .{
            .offset = @intFromPtr(lo),
            .size = total_capacity - @sizeOf(Block),
            .next_free = null,
            .prev_free = null,
            .next_physical = null,
            .prev_physical = null,
        };

        const lo_addr = @intFromPtr(lo);
        const end_addr = lo_addr + total_capacity;

        var allocator: Self = .{
            .arena = arena,
            .start = @ptrCast(lo),
            .end = @ptrFromInt(end_addr),
            .blocks = undefined,
            .bin_bitmap = 0,
            .sub_bin_bitmap = undefined,
            .first_block = block,
            .stats = .{
                .total_capacity = total_capacity,
                .current_usage = 0,
                .peak_usage = 0,
                .alloc_count = 0,
                .free_count = 0,
                .alloc_failures = 0,
            },
        };
        allocator.blocks = [_]?*Block{null} ** BLOCK_COUNT;
        allocator.sub_bin_bitmap = [_]u32{0} ** BIN_COUNT;
        allocator.insertFreeBlock(block);
        return allocator;
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
        var s = self.stats;
        var largest: usize = 0;
        for (self.blocks) |block| {
            if (block) |b| {
                if (b.size > largest) largest = b.size;
            }
        }
        s.largest_free_block = largest;
        return s;
    }

    fn getArena(ctx: *anyopaque) Arena {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.arena;
    }

    pub fn interface(self: *Self) common.Interface {
        return .{
            .ptr = self,
            .vtable = &.{
                .stdInterface = stdInterface,
                .getStats = getStats,
                .getArena = getArena,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *Self = @ptrCast(@alignCast(ctx));

        if (len == 0) return null;

        const size = std.mem.alignForward(usize, len, MIN_ALIGNMENT);

        const block_map = self.findFreeBlock(size) catch {
            self.stats.alloc_failures += 1;
            return null;
        };

        const block = self.blocks[block_map.idx].?;
        self.removeFreeBlock(block, block_map);

        const maybe_split_block = self.useFreeBlock(block, size, alignment.toByteUnits());

        if (maybe_split_block) |split_block| {
            self.insertFreeBlock(split_block);
        }

        if (!block.isFree()) {
            self.stats.alloc_count += 1;
            self.stats.current_usage += block.size;
            if (self.stats.current_usage > self.stats.peak_usage) {
                self.stats.peak_usage = self.stats.current_usage;
            }
            return @ptrFromInt(block.offset + @sizeOf(Block));
        } else {
            self.insertFreeBlock(block);
            self.stats.alloc_failures += 1;
            return null;
        }
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        _ = alignment;
        _ = ret_addr;
        const self: *Self = @ptrCast(@alignCast(ctx));

        const mem_addr = @intFromPtr(memory.ptr);

        if (mem_addr < @intFromPtr(self.start) or mem_addr >= @intFromPtr(self.end)) {
            std.log.err("free: INVALID ADDR {} (valid: {}-{})", .{ mem_addr, @intFromPtr(self.start), @intFromPtr(self.end) });
            return;
        }

        const block: *Block = @ptrFromInt(mem_addr - @sizeOf(Block));

        block.markFree();
        const merged = self.mergeFreeBlock(block);
        self.insertFreeBlock(merged);

        self.stats.free_count += 1;
        self.stats.current_usage -= memory.len;
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

    fn bitScanMsb(mask: usize) u8 {
        return 63 - @clz(mask);
    }

    fn bitScanLsb(mask: usize) u8 {
        return @ctz(mask);
    }

    fn isPowTwo(num: usize) bool {
        return (num & (num - 1)) == 0 and num > 1;
    }

    fn binmapDown(size: usize) BlockMap {
        if (size == 0) return .{
            .bin_idx = 0,
            .sub_bin_idx = 0,
            .rounded_size = 0,
            .idx = 0,
        };

        const log2_size = std.math.log2(size);

        var bin_idx: u32 = 0;
        var sub_bin_idx: u32 = 0;

        if (log2_size >= LINEAR) {
            bin_idx = log2_size - LINEAR;
            if (log2_size >= SUB_BIN) {
                const diff = log2_size - SUB_BIN;
                const shift_amt: u5 = @intCast(diff);
                const size_in_bin = size >> shift_amt;
                sub_bin_idx = @intCast(size_in_bin & (SUB_BIN_COUNT - 1));
            }
        }

        if (bin_idx >= BIN_COUNT) bin_idx = BIN_COUNT - 1;
        if (sub_bin_idx >= SUB_BIN_COUNT) sub_bin_idx = SUB_BIN_COUNT - 1;

        return .{
            .bin_idx = bin_idx,
            .sub_bin_idx = sub_bin_idx,
            .rounded_size = size,
            .idx = bin_idx * SUB_BIN_COUNT + sub_bin_idx,
        };
    }

    fn binmapUp(size: usize) BlockMap {
        if (size == 0) return .{
            .bin_idx = 0,
            .sub_bin_idx = 0,
            .rounded_size = MIN_ALLOC_SIZE,
            .idx = 0,
        };

        const log2_size = std.math.log2(size);

        var bin_idx: u32 = 0;
        var sub_bin_idx: u32 = 0;

        if (log2_size >= LINEAR) {
            const block_size = @as(usize, 1) << @intCast(log2_size);
            const next_size = if (size == block_size) block_size else block_size * 2;

            bin_idx = log2_size - LINEAR + 1;
            if (bin_idx >= LINEAR and log2_size >= SUB_BIN) {
                const diff = log2_size - SUB_BIN;
                const shift_amt: u5 = @intCast(diff);
                const size_in_bin = next_size >> shift_amt;
                sub_bin_idx = @intCast(size_in_bin & (SUB_BIN_COUNT - 1));
            }
        }

        if (bin_idx >= BIN_COUNT) bin_idx = BIN_COUNT - 1;
        if (sub_bin_idx >= SUB_BIN_COUNT) sub_bin_idx = SUB_BIN_COUNT - 1;

        const rounded_size = if (bin_idx == BIN_COUNT - 1) size else (@as(usize, 1) << @intCast(bin_idx + LINEAR));

        return .{
            .bin_idx = bin_idx,
            .sub_bin_idx = sub_bin_idx,
            .rounded_size = rounded_size,
            .idx = bin_idx * SUB_BIN_COUNT + sub_bin_idx,
        };
    }

    fn findFreeBlock(self: *Self, size: usize) !BlockMap {
        var map = binmapUp(size);

        var sub_bin_bitmap = self.sub_bin_bitmap[map.bin_idx] & (~@as(u32, 0) << @intCast(map.sub_bin_idx));

        if (sub_bin_bitmap == 0) {
            const bin_bitmap = self.bin_bitmap & (~@as(u32, 0) << @intCast(map.bin_idx + 1));
            if (bin_bitmap == 0) return error.OutOfMemory;

            map.bin_idx = @ctz(bin_bitmap);
            sub_bin_bitmap = self.sub_bin_bitmap[map.bin_idx];
        }

        map.sub_bin_idx = @ctz(sub_bin_bitmap);
        map.idx = map.bin_idx * SUB_BIN_COUNT + map.sub_bin_idx;

        return map;
    }

    fn insertFreeBlock(self: *Self, block: *Block) void {
        std.debug.assert(block.size > 0);
        const map = binmapDown(block.size);
        const idx = map.idx;
        const current = self.blocks[idx];

        block.prev_free = null;
        block.next_free = current;
        if (current) |curr| {
            curr.prev_free = block;
        }
        self.blocks[idx] = block;
        self.bin_bitmap |= @as(u32, 1) << @intCast(map.bin_idx);
        self.sub_bin_bitmap[map.bin_idx] |= @as(u32, 1) << @intCast(map.sub_bin_idx);
    }

    fn removeFreeBlock(self: *Self, block: *Block, block_map: BlockMap) void {
        const next = block.next_free;
        const prev = block.prev_free;

        if (next) |n| n.prev_free = prev;
        if (prev) |p| p.next_free = next;

        if (self.blocks[block_map.idx] == block) {
            self.blocks[block_map.idx] = next;
            if (next == null) {
                self.sub_bin_bitmap[block_map.bin_idx] &= ~(@as(u32, 1) << @intCast(block_map.sub_bin_idx));
                if (self.sub_bin_bitmap[block_map.bin_idx] == 0) {
                    self.bin_bitmap &= ~(@as(u32, 1) << @intCast(block_map.bin_idx));
                }
            }
        }
    }

    fn useFreeBlock(self: *Self, block: *Block, size: usize, alignment: usize) ?*Block {
        const aligned_offset = std.mem.alignForward(usize, block.offset + @sizeOf(Block), alignment);
        const adjustment: usize = aligned_offset - (block.offset + @sizeOf(Block));
        // Round up to @alignOf(Block) so the next block header starts at a properly aligned address.
        const size_with_adjustment = std.mem.alignForward(usize, size + adjustment, @alignOf(Block));

        if (size_with_adjustment > block.size) return null;

        var maybe_new_block: ?*Block = null;
        const min_split_size = MIN_ALLOC_SIZE + @sizeOf(Block);
        if (block.size >= size_with_adjustment + @sizeOf(Block) + min_split_size) {
            const remaining_size = block.size - size_with_adjustment - @sizeOf(Block);
            const new_block_end = block.offset + @sizeOf(Block) + size_with_adjustment + @sizeOf(Block) + remaining_size;
            if (new_block_end > @intFromPtr(self.end)) {
                return null;
            }

            const next_physical = block.next_physical;
            const new_block_addr = block.offset + @sizeOf(Block) + size_with_adjustment;
            const new_block: *Block = @ptrFromInt(new_block_addr);
            new_block.* = .{
                .offset = new_block_addr,
                .size = remaining_size,
                .next_free = null,
                .prev_free = null,
                .next_physical = next_physical,
                .prev_physical = block,
            };
            maybe_new_block = new_block;

            if (next_physical) |np| {
                np.prev_physical = new_block;
            }
            block.next_physical = new_block;
        }

        block.size = size_with_adjustment;
        block.markUsed();

        return maybe_new_block;
    }

    fn mergeFreeBlock(self: *Self, block: *Block) *Block {
        var result: *Block = block;

        if (block.prev_physical) |prev_physical| {
            if (prev_physical.isFree()) {
                const map = binmapDown(prev_physical.size);
                self.removeFreeBlock(prev_physical, map);

                // prev_physical absorbs block: its header stays at its own address,
                // maintaining the invariant block.offset == @intFromPtr(block).
                prev_physical.size += @sizeOf(Block) + block.size;
                prev_physical.next_physical = block.next_physical;
                if (block.next_physical) |next| {
                    next.prev_physical = prev_physical;
                }
                result = prev_physical;
            }
        }

        if (result.next_physical) |next_physical| {
            if (next_physical.isFree()) {
                const map = binmapDown(next_physical.size);
                self.removeFreeBlock(next_physical, map);

                result.size += @sizeOf(Block) + next_physical.size;
                result.next_physical = next_physical.next_physical;
                if (next_physical.next_physical) |next_next| {
                    next_next.prev_physical = result;
                }
            }
        }

        return result;
    }
};

test "tlsf init and deinit" {
    var allocator = try TlsfAllocator.init(.MEM_2, null);
    defer allocator.deinit();
    if (allocator.stats.total_capacity == 0) return error.InitFail;
    if (allocator.stats.alloc_count != 0) return error.InitFail2;
}

test "tlsf basic alloc free" {
    var allocator = try TlsfAllocator.init(.MEM_2, null);
    defer allocator.deinit();
    const alloc = allocator.interface().stdInterface();
    const ptr = alloc.rawAlloc(64, .@"1", @returnAddress()) orelse return error.AllocFail;
    if (allocator.stats.alloc_count != 1) return error.AllocCnt;
    alloc.rawFree(ptr[0..64], .@"1", @returnAddress());
    if (allocator.stats.free_count != 1) return error.FreeCnt;
}

test "tlsf multiple allocations" {
    var allocator = try TlsfAllocator.init(.MEM_2, null);
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

test "tlsf reallocate after free" {
    var allocator = try TlsfAllocator.init(.MEM_2, null);
    defer allocator.deinit();
    const alloc = allocator.interface().stdInterface();
    const p1 = alloc.rawAlloc(64, .@"1", @returnAddress()) orelse return error.A1;
    if (allocator.stats.alloc_count != 1) return error.CheckA1;
    alloc.rawFree(p1[0..64], .@"1", @returnAddress());
    if (allocator.stats.free_count != 1) return error.CheckF1;
    if (allocator.bin_bitmap == 0) return error.CheckB;
    const initial_free_count = allocator.stats.free_count;
    const initial_current = allocator.stats.current_usage;
    const p2: ?[*]u8 = alloc.rawAlloc(64, .@"1", @returnAddress());
    if (p2 == null) {
        return error.A2Null;
    }
    if (allocator.stats.alloc_count != 2) return error.CheckA2;
    if (allocator.stats.free_count != initial_free_count) return error.CheckF2;
    if (allocator.stats.current_usage != initial_current + 64) return error.CheckUsg;
}

test "sentinel block handling" {
    var tlsf = try TlsfAllocator.init(.MEM_2, 1024 * 256);
    defer tlsf.deinit();
    const alloc = tlsf.interface().stdInterface();
    _ = alloc.rawAlloc(64, .@"1", @returnAddress()) orelse return error.SentinelAlloc;
    if (tlsf.stats.current_usage == 0) return error.SentinelNoUsage;
}

test "tlsf small remainder after alloc" {
    var allocator = try TlsfAllocator.init(.MEM_2, 4096);
    defer allocator.deinit();
    const alloc = allocator.interface().stdInterface();

    _ = alloc.rawAlloc(256, .@"1", @returnAddress()) orelse return error.A1;

    const p2 = alloc.rawAlloc(3584, .@"1", @returnAddress());
    if (p2 == null and allocator.stats.alloc_failures == 0) return error.ShouldFail;
}

test "tlsf exact min alloc repeatedly" {
    var allocator = try TlsfAllocator.init(.MEM_2, 4096);
    defer allocator.deinit();
    const alloc = allocator.interface().stdInterface();

    const size: usize = MIN_ALLOC_SIZE;
    var ptrs: [20]?[*]u8 = undefined;
    for (&ptrs) |*p| {
        p.* = alloc.rawAlloc(size, .@"1", @returnAddress());
    }
    for (ptrs) |p| {
        if (p == null) return error.ShouldSucceed;
    }
}

test "block merge linking with prev" {
    var tlsf = try TlsfAllocator.init(.MEM_2, 1024 * 256);
    defer tlsf.deinit();
    const alloc = tlsf.interface().stdInterface();
    const p1 = alloc.rawAlloc(32, .@"1", @returnAddress()) orelse return error.Merge1;
    const p2 = alloc.rawAlloc(32, .@"1", @returnAddress()) orelse return error.Merge2;
    alloc.rawFree(p1[0..32], .@"1", @returnAddress());
    alloc.rawFree(p2[0..32], .@"1", @returnAddress());
    if (tlsf.stats.free_count != 2) return error.MergeFreeCount;
}

test "free list self-pointers" {
    var tlsf = try TlsfAllocator.init(.MEM_2, 1024 * 256);
    defer tlsf.deinit();
    const alloc = tlsf.interface().stdInterface();
    const ptr = alloc.rawAlloc(64, .@"1", @returnAddress()) orelse return error.SelfPtrAlloc;
    const before = tlsf.stats.free_count;
    alloc.rawFree(ptr[0..64], .@"1", @returnAddress());
    const after = tlsf.stats.free_count;
    if (after != before + 1) return error.SelfPtrFreeCount;
}

test "double remove safety" {
    var tlsf = try TlsfAllocator.init(.MEM_2, 1024 * 256);
    defer tlsf.deinit();
    const alloc = tlsf.interface().stdInterface();
    const ptr = alloc.rawAlloc(64, .@"1", @returnAddress()) orelse return error.DoubleAlloc;
    alloc.rawFree(ptr[0..64], .@"1", @returnAddress());
}

test "coalesce adjacent free" {
    var tlsf = try TlsfAllocator.init(.MEM_2, 1024 * 256);
    defer tlsf.deinit();
    const alloc = tlsf.interface().stdInterface();
    const p1 = alloc.rawAlloc(32, .@"1", @returnAddress()) orelse return error.Coalesce1;
    const p2 = alloc.rawAlloc(32, .@"1", @returnAddress()) orelse return error.Coalesce2;
    const p3 = alloc.rawAlloc(32, .@"1", @returnAddress()) orelse return error.Coalesce3;
    alloc.rawFree(p1[0..32], .@"1", @returnAddress());
    alloc.rawFree(p2[0..32], .@"1", @returnAddress());
    alloc.rawFree(p3[0..32], .@"1", @returnAddress());
    if (tlsf.stats.free_count != 3) return error.CoalesceFreeCount;
}

test "alternating alloc free" {
    var tlsf = try TlsfAllocator.init(.MEM_2, 1024 * 512);
    defer tlsf.deinit();
    const alloc = tlsf.interface().stdInterface();
    const p1 = alloc.rawAlloc(32, .@"1", @returnAddress()) orelse return error.Alt1;
    const p2 = alloc.rawAlloc(32, .@"1", @returnAddress()) orelse return error.Alt2;
    const p3 = alloc.rawAlloc(32, .@"1", @returnAddress()) orelse return error.Alt3;
    alloc.rawFree(p1[0..32], .@"1", @returnAddress());
    alloc.rawFree(p2[0..32], .@"1", @returnAddress());
    alloc.rawFree(p3[0..32], .@"1", @returnAddress());
    if (tlsf.stats.free_count != 3) return error.AltFreeCount;
}

test "many small allocs then free" {
    var tlsf = try TlsfAllocator.init(.MEM_2, 1024 * 256);
    defer tlsf.deinit();
    const alloc = tlsf.interface().stdInterface();
    const p1 = alloc.rawAlloc(16, .@"1", @returnAddress()) orelse return error.Many1;
    const p2 = alloc.rawAlloc(16, .@"1", @returnAddress()) orelse return error.Many2;
    const p3 = alloc.rawAlloc(16, .@"1", @returnAddress()) orelse return error.Many3;
    alloc.rawFree(p3[0..16], .@"1", @returnAddress());
    alloc.rawFree(p2[0..16], .@"1", @returnAddress());
    alloc.rawFree(p1[0..16], .@"1", @returnAddress());
    if (tlsf.stats.free_count != 3) return error.ManyFreeCount;
}

test "alloc exact size no split" {
    var tlsf = try TlsfAllocator.init(.MEM_2, 1024 * 256);
    defer tlsf.deinit();
    const alloc = tlsf.interface().stdInterface();
    const before = tlsf.stats.current_usage;
    const ptr = alloc.rawAlloc(MIN_ALLOC_SIZE, .@"1", @returnAddress()) orelse return error.ExactAlloc;
    const after = tlsf.stats.current_usage;
    if (after <= before) return error.ExactNoChange;
    alloc.rawFree(ptr[0..MIN_ALLOC_SIZE], .@"1", @returnAddress());
}

test "split then merge cycle" {
    var tlsf = try TlsfAllocator.init(.MEM_2, 1024 * 256);
    defer tlsf.deinit();
    const alloc = tlsf.interface().stdInterface();
    const p1 = alloc.rawAlloc(32, .@"1", @returnAddress()) orelse return error.Cycle1;
    const p2 = alloc.rawAlloc(32, .@"1", @returnAddress()) orelse return error.Cycle2;
    alloc.rawFree(p1[0..32], .@"1", @returnAddress());
    alloc.rawFree(p2[0..32], .@"1", @returnAddress());
    if (tlsf.stats.free_count != 2) return error.CycleFreeCount;
}

test "random alloc free pattern" {
    var tlsf = try TlsfAllocator.init(.MEM_2, 1024 * 512);
    defer tlsf.deinit();
    const alloc = tlsf.interface().stdInterface();
    const p1 = alloc.rawAlloc(32, .@"1", @returnAddress()) orelse return error.Rand1;
    const p2 = alloc.rawAlloc(48, .@"1", @returnAddress()) orelse return error.Rand2;
    alloc.rawFree(p1[0..32], .@"1", @returnAddress());
    alloc.rawFree(p2[0..48], .@"1", @returnAddress());
    if (tlsf.stats.alloc_count != 2 or tlsf.stats.free_count != 2) return error.RandCount;
}

test "tlsf with capacity parameter" {
    const capacity: usize = 8192;
    var allocator = try TlsfAllocator.init(.MEM_2, capacity);
    defer allocator.deinit();
    if (allocator.stats.total_capacity != capacity) return error.Capacity;
    const alloc = allocator.interface().stdInterface();
    _ = alloc.rawAlloc(1024, .@"1", @returnAddress()) orelse return error.Alloc;
    if (allocator.stats.current_usage != 1024) return error.Usage;
}
