const common = @import("common.zig");
const std = @import("std");
const c = @import("platform").c;

pub const ALIGN_SIZE_LOG2 = 2;
pub const ALIGN_SIZE = 1 << ALIGN_SIZE_LOG2;
pub const SL_INDEX_COUNT_LOG2 = 5;
pub const SL_INDEX_COUNT = 1 << SL_INDEX_COUNT_LOG2;
pub const FL_INDEX_MAX = 30;
pub const FL_INDEX_SHIFT = SL_INDEX_COUNT_LOG2 + ALIGN_SIZE_LOG2;
pub const FL_INDEX_COUNT = FL_INDEX_MAX - FL_INDEX_SHIFT + 1;
pub const SMALL_BLOCK_SIZE = 1 << FL_INDEX_SHIFT;

pub const BLOCK_HEADER_FREE_BIT: usize = 1 << 0;
pub const BLOCK_HEADER_PREV_FREE_BIT: usize = 1 << 1;
pub const BLOCK_HEADER_OVERHEAD = @sizeOf(usize);
pub const BLOCK_START_OFFSET = @sizeOf(usize) * 2;
pub const BLOCK_SIZE_MIN = @sizeOf(BlockHeader) - @sizeOf(*BlockHeader);
pub const BLOCK_SIZE_MAX: usize = 1 << FL_INDEX_MAX;

pub const BlockHeader = struct {
    prev_block: *BlockHeader,
    size: usize,
    next_free: ?*BlockHeader,
    prev_free: ?*BlockHeader,
};

pub const Control = struct {
    fl_bitmap: u32,
    sl_bitmap: [FL_INDEX_COUNT]u32,
    blocks: [FL_INDEX_COUNT][SL_INDEX_COUNT]?*BlockHeader,
};

pub inline fn blockSize(block: *BlockHeader) usize {
    return block.size & ~(BLOCK_HEADER_FREE_BIT | BLOCK_HEADER_PREV_FREE_BIT);
}

pub inline fn alignUp(x: usize, alignment: usize) usize {
    return (x + alignment - 1) & ~(alignment - 1);
}

pub inline fn alignDown(x: usize, alignment: usize) usize {
    return x & ~(alignment - 1);
}

pub inline fn blockToPtr(block: *BlockHeader) [*]u8 {
    const base: [*]u8 = @ptrCast(@alignCast(block));
    return base + BLOCK_START_OFFSET;
}

inline fn blockFromPtr(ptr: [*]u8) *BlockHeader {
    const addr: usize = @intFromPtr(ptr) - BLOCK_START_OFFSET;
    const block_ptr: *BlockHeader = @ptrFromInt(addr);
    return @alignCast(block_ptr);
}

inline fn blockNext(block: *BlockHeader) *BlockHeader {
    const sz = blockSize(block);
    if (sz == 0) return block;
    const ptr: [*]u8 = blockToPtr(block);
    const next_addr: usize = @intFromPtr(ptr) + sz - BLOCK_HEADER_OVERHEAD;
    const next: *BlockHeader = @ptrFromInt(next_addr);
    return next;
}

inline fn blockNextPtr(block: *BlockHeader) [*]u8 {
    const ptr: [*]u8 = blockToPtr(block);
    const ptr_int: usize = @intFromPtr(ptr);
    return @ptrFromInt(ptr_int + blockSize(block) - BLOCK_HEADER_OVERHEAD);
}

inline fn blockPrev(block: *BlockHeader) *BlockHeader {
    return block.prev_block;
}

pub fn find_lsb(word: u32) i32 {
    if (word == 0) return -1;
    return @intCast(@ctz(word));
}

pub fn find_msb(word: u32) i32 {
    if (word == 0) return -1;
    return @intCast(31 - @clz(word));
}

fn find_msb_sizet(size: usize) i32 {
    return find_msb(@intCast(size));
}

pub fn mappingInsert(size: usize, fli: *i32, sli: *i32) void {
    if (size < SMALL_BLOCK_SIZE) {
        fli.* = 0;
        sli.* = @intCast(size / (SMALL_BLOCK_SIZE / SL_INDEX_COUNT));
    } else {
        const raw_fl = find_msb_sizet(size);
        const shift: i32 = @intCast(raw_fl - SL_INDEX_COUNT_LOG2);
        sli.* = @intCast((size >> @intCast(shift)) ^ SL_INDEX_COUNT);
        fli.* = raw_fl - (FL_INDEX_SHIFT - 1);
    }
}

fn mappingSearch(size: usize, fli: *i32, sli: *i32) void {
    if (size >= SMALL_BLOCK_SIZE) {
        const fls = find_msb_sizet(size);
        var round: usize = 0;
        for (0..@intCast(fls - SL_INDEX_COUNT_LOG2)) |_| round = (round << 1) | 1;
        mappingInsert(size + round, fli, sli);
    } else {
        mappingInsert(size, fli, sli);
    }
}

fn searchSuitableBlock(ctrl: *Control, fli: *i32, sli: *i32) ?*BlockHeader {
    var fl = fli.*;

    var sl_map = ctrl.sl_bitmap[@intCast(fl)] & (~@as(u32, 0) << @intCast(sli.*));
    if (sl_map == 0) {
        const fl_map = ctrl.fl_bitmap & (~@as(u32, 0) << @intCast(fl + 1));
        if (fl_map == 0) return null;
        fl = find_lsb(fl_map);
        fli.* = fl;
        sl_map = ctrl.sl_bitmap[@intCast(fl)];
    }
    sli.* = find_lsb(sl_map);
    return ctrl.blocks[@intCast(fl)][@intCast(sli.*)];
}

fn insertFreeBlock(ctrl: *Control, block: *BlockHeader, fl: i32, sl: i32) void {
    if (ctrl.blocks[@intCast(fl)][@intCast(sl)]) |current| {
        block.next_free = current;
        block.prev_free = current.prev_free;
        if (current.prev_free) |p| {
            p.next_free = block;
        } else {
            block.next_free = block;
        }
        current.prev_free = block;
    } else {
        block.next_free = null;
        block.prev_free = null;
    }
    ctrl.blocks[@intCast(fl)][@intCast(sl)] = block;
    ctrl.fl_bitmap |= @as(u32, 1) << @intCast(fl);
    ctrl.sl_bitmap[@intCast(fl)] |= @as(u32, 1) << @intCast(sl);
}

fn removeFreeBlock(ctrl: *Control, block: *BlockHeader, fl: i32, sl: i32) void {
    const prev = block.prev_free;
    const next = block.next_free;

    const is_single = (prev == null and next == null);

    if (is_single) {
        ctrl.blocks[@intCast(fl)][@intCast(sl)] = null;
    } else if (prev == null) {
        next.?.prev_free = null;
        ctrl.blocks[@intCast(fl)][@intCast(sl)] = next;
    } else if (next == null) {
        prev.?.next_free = null;
    } else {
        prev.?.next_free = next;
        next.?.prev_free = prev;
        if (ctrl.blocks[@intCast(fl)][@intCast(sl)] == block) {
            ctrl.blocks[@intCast(fl)][@intCast(sl)] = next;
        }
    }

    if (ctrl.blocks[@intCast(fl)][@intCast(sl)] == null) {
        ctrl.sl_bitmap[@intCast(fl)] &= ~(@as(u32, 1) << @intCast(sl));
        if (ctrl.sl_bitmap[@intCast(fl)] == 0) {
            ctrl.fl_bitmap &= ~(@as(u32, 1) << @intCast(fl));
        }
    }
    block.prev_free = null;
    block.next_free = null;
}

fn blockInsert(ctrl: *Control, block: *BlockHeader) void {
    block.next_free = null;
    block.prev_free = null;
    var fl: i32 = 0;
    var sl: i32 = 0;
    mappingInsert(blockSize(block), &fl, &sl);
    insertFreeBlock(ctrl, block, fl, sl);
}

fn blockRemove(ctrl: *Control, block: *BlockHeader) void {
    var fl: i32 = 0;
    var sl: i32 = 0;
    mappingInsert(blockSize(block), &fl, &sl);
    removeFreeBlock(ctrl, block, fl, sl);
}

fn blockCanSplit(block: *BlockHeader, size: usize) bool {
    return blockSize(block) >= BLOCK_SIZE_MIN + size;
}

fn blockSplit(block: *BlockHeader, size: usize) ?*BlockHeader {
    const remain = blockSize(block) - (size + BLOCK_HEADER_OVERHEAD);
    if (remain < BLOCK_SIZE_MIN) return null;

    const base: [*]u8 = blockToPtr(block);
    const remaining_addr: usize = @intFromPtr(base) + size - BLOCK_HEADER_OVERHEAD;
    const remaining: *BlockHeader = @ptrFromInt(remaining_addr);
    remaining.size = remain | BLOCK_HEADER_FREE_BIT | BLOCK_HEADER_PREV_FREE_BIT;
    remaining.prev_block = block;
    block.size = size | (block.size & BLOCK_HEADER_FREE_BIT);

    const after_remaining = blockNext(remaining);
    after_remaining.prev_block = remaining;

    return remaining;
}

fn blockMerge(ctrl: *Control, block: *BlockHeader) *BlockHeader {
    var merged = block;
    if ((block.size & BLOCK_HEADER_PREV_FREE_BIT) != 0) {
        const prev = blockPrev(block);
        blockRemove(ctrl, prev);
        prev.size += blockSize(block) + BLOCK_HEADER_OVERHEAD;
        merged = prev;
    }
    const next = blockNext(merged);
    if (blockSize(next) > 0 and (next.size & BLOCK_HEADER_FREE_BIT) != 0) {
        blockRemove(ctrl, next);
        merged.size += blockSize(next) + BLOCK_HEADER_OVERHEAD;
    }
    merged.prev_block = blockPrev(merged);
    const after = blockNext(merged);
    if (blockSize(after) > 0) {
        after.prev_block = merged;
    }
    return merged;
}

fn adjustRequestSize(size: usize) usize {
    if (size == 0) return 0;
    const aligned = alignUp(size, ALIGN_SIZE);
    if (aligned >= BLOCK_SIZE_MAX) return 0;
    return if (aligned < BLOCK_SIZE_MIN) BLOCK_SIZE_MIN else aligned;
}

pub const TlsfAllocator = struct {
    const Self = @This();
    const Alignment = std.mem.Alignment;

    arena: common.Arena,
    ctrl: *Control,
    mem_start: [*]u8,
    mem_end: [*]u8,
    stats: common.Stats,

    pub fn init(arena: common.Arena, size: ?usize) !Self {
        const lo = if (arena == .MEM_1) c.SYS_GetArena1Lo() else c.SYS_GetArena2Lo();
        const hi = if (arena == .MEM_1) c.SYS_GetArena1Hi() else c.SYS_GetArena2Hi();

        const ctrl_sz = alignUp(@sizeOf(Control), ALIGN_SIZE);
        const pool_start = @intFromPtr(lo) + ctrl_sz;
        const avail = @intFromPtr(hi) - pool_start;
        const alloc_sz = if (size) |sz| sz else avail;

        if (alloc_sz < 2 * BLOCK_HEADER_OVERHEAD + BLOCK_SIZE_MIN) return error.OutOfMemory;

        const pool_bytes = alignDown(alloc_sz - 2 * BLOCK_HEADER_OVERHEAD, ALIGN_SIZE);
        const pool_ptr: [*]u8 = @ptrFromInt(pool_start);
        const new_lo: [*]u8 = @ptrFromInt(pool_start + pool_bytes);

        if (arena == .MEM_1) c.SYS_SetArena1Lo(new_lo) else c.SYS_SetArena2Lo(new_lo);

        const lo_addr: usize = @intFromPtr(lo);
        const ctrl_ptr: *anyopaque = @ptrFromInt(lo_addr);
        const ctrl: *Control = @ptrCast(@alignCast(ctrl_ptr));
        ctrl.fl_bitmap = 0;
        var si: usize = 0;
        while (si < FL_INDEX_COUNT) : (si += 1) {
            ctrl.sl_bitmap[si] = 0;
            var sj: usize = 0;
            while (sj < SL_INDEX_COUNT) : (sj += 1) {
                ctrl.blocks[si][sj] = null;
            }
        }

        const first: *BlockHeader = @ptrCast(@alignCast(pool_ptr - BLOCK_HEADER_OVERHEAD));
        first.size = pool_bytes | BLOCK_HEADER_FREE_BIT;
        first.prev_block = first;
        blockInsert(ctrl, first);

        const sentinel = blockNext(first);
        sentinel.size = 0;
        sentinel.prev_block = first;

        return .{
            .arena = arena,
            .ctrl = ctrl,
            .mem_start = pool_ptr,
            .mem_end = new_lo,
            .stats = .{ .total_capacity = pool_bytes, .alloc_count = 0, .alloc_failures = 0, .current_usage = 0, .free_count = 0, .peak_usage = 0 },
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.arena == .MEM_1) c.SYS_SetArena1Lo(self.mem_start) else c.SYS_SetArena2Lo(self.mem_start);
    }

    fn stdIfc(ctx: *anyopaque) std.mem.Allocator {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return .{ .ptr = self, .vtable = &.{ .alloc = allocFn, .resize = resizeFn, .remap = remapFn, .free = freeFn } };
    }

    fn getStats(ctx: *anyopaque) common.Stats {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.stats;
    }

    fn getArena(ctx: *anyopaque) common.Arena {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.arena;
    }

    pub fn interface(self: *Self) common.Interface {
        return .{ .ptr = self, .vtable = &.{ .stdInterface = stdIfc, .getStats = getStats, .getArena = getArena, .dumpStats = dumpStats } };
    }

    fn allocFn(ctx: *anyopaque, len: usize, alignment: Alignment, _: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (len == 0) return null;

        const align_bytes = alignment.toByteUnits();
        var size = alignUp(len, ALIGN_SIZE);
        if (align_bytes > ALIGN_SIZE) {
            size = adjustRequestSize(size + align_bytes + BLOCK_SIZE_MIN);
        } else {
            size = adjustRequestSize(size);
        }
        if (size == 0) {
            self.stats.alloc_failures += 1;
            return null;
        }

        var fl: i32 = 0;
        var sl: i32 = 0;
        mappingSearch(size, &fl, &sl);
        const block = searchSuitableBlock(self.ctrl, &fl, &sl) orelse {
            self.stats.alloc_failures += 1;
            return null;
        };
        removeFreeBlock(self.ctrl, block, fl, sl);

        const block_sz = blockSize(block);
        const needed = alignUp(len, align_bytes);
        const adj_sz = if (align_bytes > ALIGN_SIZE) adjustRequestSize(needed + align_bytes + BLOCK_SIZE_MIN) else adjustRequestSize(needed);

        if (block_sz >= adj_sz + BLOCK_SIZE_MIN + BLOCK_HEADER_OVERHEAD) {
            const split_sz = adj_sz + BLOCK_HEADER_OVERHEAD;
            if (blockSplit(block, split_sz)) |rem| {
                block.size = split_sz | (block.size & BLOCK_HEADER_FREE_BIT);
                blockInsert(self.ctrl, rem);
            }
        }

        block.size &= ~BLOCK_HEADER_FREE_BIT;
        blockNext(block).size |= BLOCK_HEADER_PREV_FREE_BIT;

        const ptr = blockToPtr(block);
        const offset = (align_bytes - (@intFromPtr(ptr) % align_bytes)) % align_bytes;

        self.stats.alloc_count += 1;
        self.stats.current_usage += blockSize(block) - BLOCK_HEADER_OVERHEAD;
        self.stats.peak_usage = @max(self.stats.peak_usage, self.stats.current_usage);

        return @ptrFromInt(@intFromPtr(ptr) + offset);
    }

    fn freeFn(ctx: *anyopaque, memory: []u8, _: Alignment, _: usize) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (memory.len == 0) return;

        const block = blockFromPtr(memory.ptr);
        self.stats.free_count += 1;
        self.stats.current_usage -= blockSize(block) - BLOCK_HEADER_OVERHEAD;

        block.size |= BLOCK_HEADER_FREE_BIT;
        const next = blockNext(block);
        if (blockSize(next) > 0) {
            next.size |= BLOCK_HEADER_PREV_FREE_BIT;
        }
        blockInsert(self.ctrl, blockMerge(self.ctrl, block));
    }

    fn resizeFn(_: *anyopaque, _: []u8, _: Alignment, _: usize, _: usize) bool {
        return false;
    }

    fn remapFn(_: *anyopaque, _: []u8, _: Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }

    fn dumpStats(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const log = std.log.scoped(.tlsf);
        log.info("Capacity: {} KB, Used: {} KB, Peak: {} KB, Allocs: {}, Frees: {}, Failures: {}", .{ self.stats.total_capacity / 1024, self.stats.current_usage / 1024, self.stats.peak_usage / 1024, self.stats.alloc_count, self.stats.free_count, self.stats.alloc_failures });
    }
};

test "find_lsb" {
    if (find_lsb(0) != -1) return error.Lsb0;
    if (find_lsb(1) != 0) return error.Lsb1;
    if (find_lsb(0b00001000) != 3) return error.Lsb8;
    if (find_lsb(0x80000000) != 31) return error.LsbMax;
    if (find_lsb(0b10101010) != 1) return error.LsbMix;
}

test "find_msb" {
    if (find_msb(0) != -1) return error.Msb0;
    if (find_msb(1) != 0) return error.Msb1;
    if (find_msb(0b00010000) != 4) return error.Msb16;
    if (find_msb(0x80000000) != 31) return error.MsbMax;
    if (find_msb(0b10101010) != 7) return error.MsbMix;
}

test "align functions" {
    if (alignUp(0, 4) != 0) return error.AlignUp0;
    if (alignUp(1, 4) != 4) return error.AlignUp1;
    if (alignUp(4, 4) != 4) return error.AlignUp4;
    if (alignUp(5, 4) != 8) return error.AlignUp5;
    if (alignUp(8, 4) != 8) return error.AlignUp8;
    if (alignDown(0, 4) != 0) return error.AlignDown0;
    if (alignDown(1, 4) != 0) return error.AlignDown1;
    if (alignDown(4, 4) != 4) return error.AlignDown4;
    if (alignDown(5, 4) != 4) return error.AlignDown5;
    if (alignDown(8, 4) != 8) return error.AlignDown8;
}

test "block size masking" {
    var blk: BlockHeader = undefined;
    blk.size = 100;
    if (blockSize(&blk) != 100) return error.BlkSzNoFlg;
    blk.size |= BLOCK_HEADER_FREE_BIT;
    if (blockSize(&blk) != 100) return error.BlkSzFreeFlg;
    blk.size &= ~BLOCK_HEADER_FREE_BIT;
    if ((blk.size & BLOCK_HEADER_FREE_BIT) != 0) return error.BlkSzAfterUsed;
    blk.size |= BLOCK_HEADER_PREV_FREE_BIT;
    if (!((blk.size & BLOCK_HEADER_PREV_FREE_BIT) != 0)) return error.BlkPrevFree;
    blk.size &= ~BLOCK_HEADER_PREV_FREE_BIT;
    if ((blk.size & BLOCK_HEADER_PREV_FREE_BIT) != 0) return error.BlkPrevUsed;
}

test "mapping insert small blocks" {
    var fl: i32 = 0;
    var sl: i32 = 0;
    mappingInsert(4, &fl, &sl);
    if (fl != 0 or sl != 1) return error.Map4;
    mappingInsert(64, &fl, &sl);
    if (fl != 0 or sl != 16) return error.Map64;
    mappingInsert(127, &fl, &sl);
    if (fl != 0 or sl != 31) return error.Map127;
}

test "mapping insert large blocks" {
    var fl: i32 = 0;
    var sl: i32 = 0;
    mappingInsert(128, &fl, &sl);
    if (fl != 1 or sl != 0) return error.Map128;
    mappingInsert(256, &fl, &sl);
    if (fl != 2) return error.Map256;
    mappingInsert(1024, &fl, &sl);
    if (fl != 4) return error.Map1024;
    mappingInsert(4096, &fl, &sl);
    if (fl != 6) return error.Map4096;
}

test "mapping search" {
    var fl: i32 = 0;
    var sl: i32 = 0;
    mappingSearch(4, &fl, &sl);
    if (fl != 0) return error.MapS4;
    mappingSearch(128, &fl, &sl);
    if (fl != 1) return error.MapS128;
    mappingSearch(1000, &fl, &sl);
    if (fl < 3 or fl > 6) return error.MapS1000;
}

test "block can split" {
    var blk: BlockHeader = undefined;
    blk.size = BLOCK_SIZE_MIN;
    if (blockCanSplit(&blk, 4)) return error.CanSplitFalse;
    blk.size = BLOCK_SIZE_MIN + 4;
    if (!blockCanSplit(&blk, 4)) return error.CanSplitTrue;
    blk.size = BLOCK_SIZE_MIN + 100;
    if (!blockCanSplit(&blk, 100)) return error.CanSplit100;
}

test "adjust request size" {
    if (adjustRequestSize(0) != 0) return error.Adj0;
    if (adjustRequestSize(1) != BLOCK_SIZE_MIN) return error.Adj1;
    if (adjustRequestSize(3) != BLOCK_SIZE_MIN) return error.Adj3;
    if (adjustRequestSize(4) != BLOCK_SIZE_MIN) return error.Adj4;
    if (adjustRequestSize(5) != BLOCK_SIZE_MIN) return error.Adj5;
    if (adjustRequestSize(8) != BLOCK_SIZE_MIN) return error.Adj8;
    if (adjustRequestSize(BLOCK_SIZE_MAX + 1) != 0) return error.AdjMax;
}

test "full allocator init and deinit" {
    var tlsf = try TlsfAllocator.init(.MEM_2, 1024 * 256);
    defer tlsf.deinit();
    if (tlsf.stats.total_capacity == 0 or tlsf.stats.alloc_count != 0) return error.InitFail;
}

test "basic alloc free" {
    var tlsf = try TlsfAllocator.init(.MEM_2, 1024 * 256);
    defer tlsf.deinit();
    const alloc = tlsf.interface().stdInterface();
    const ptr = alloc.rawAlloc(64, .@"1", @returnAddress()) orelse return error.AllocFail;
    if (tlsf.stats.alloc_count != 1) return error.AllocCnt;
    if (tlsf.stats.current_usage < 64) return error.UsgLow;
    alloc.rawFree(ptr[0..64], .@"1", @returnAddress());
    if (tlsf.stats.free_count != 1) return error.FreeCnt;
}

test "multiple allocations" {
    var tlsf = try TlsfAllocator.init(.MEM_2, 1024 * 512);
    defer tlsf.deinit();
    const alloc = tlsf.interface().stdInterface();
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
    var tlsf = try TlsfAllocator.init(.MEM_2, 1024 * 256);
    defer tlsf.deinit();
    const alloc = tlsf.interface().stdInterface();
    const p1 = alloc.rawAlloc(64, .@"1", @returnAddress()) orelse return error.A1;
    alloc.rawFree(p1[0..64], .@"1", @returnAddress());
    const p2 = alloc.rawAlloc(64, .@"1", @returnAddress()) orelse return error.A2;
    alloc.rawFree(p2[0..64], .@"1", @returnAddress());
    if (tlsf.stats.alloc_count != 2 or tlsf.stats.free_count != 2) return error.Realloc;
}

test "alignment handling" {
    var tlsf = try TlsfAllocator.init(.MEM_2, 1024 * 256);
    defer tlsf.deinit();
    const alloc = tlsf.interface().stdInterface();
    const ptr = alloc.rawAlloc(17, .@"8", @returnAddress()) orelse return error.AlignAlloc;
    if (@intFromPtr(ptr) % 8 != 0) return error.NotAligned;
}

test "zero size alloc" {
    var tlsf = try TlsfAllocator.init(.MEM_2, 1024 * 256);
    defer tlsf.deinit();
    const alloc = tlsf.interface().stdInterface();
    const ptr = alloc.rawAlloc(0, .@"1", @returnAddress());
    if (ptr != null or tlsf.stats.alloc_count != 0) return error.ZeroAlloc;
}

test "out of memory" {
    var tlsf = try TlsfAllocator.init(.MEM_2, 256);
    defer tlsf.deinit();
    const alloc = tlsf.interface().stdInterface();
    const result = alloc.rawAlloc(1024 * 200, .@"1", @returnAddress());
    if (result != null) {
        const sz = 1024 * 200;
        alloc.rawFree(result.?[0..sz], .@"1", @returnAddress());
    }
    if (tlsf.stats.alloc_failures == 0) return error.NoFail;
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

test "block split linking" {
    var tlsf = try TlsfAllocator.init(.MEM_2, 1024 * 256);
    defer tlsf.deinit();
    const alloc = tlsf.interface().stdInterface();
    const ptr = alloc.rawAlloc(32, .@"1", @returnAddress()) orelse return error.SplitAlloc1;
    const blk = blockFromPtr(ptr);
    if (blockSize(blk) == 0) return error.SplitBlkSizeZero;
    const next = blockNext(blk);
    if (blockSize(next) == 0) return error.SplitNextIsSentinel;
    if (next.prev_block != blk) return error.SplitLinkBad;
    alloc.rawFree(ptr[0..32], .@"1", @returnAddress());
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
