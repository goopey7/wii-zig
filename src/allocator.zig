const std = @import("std");
const c = @import("main.zig").c;

pub const Arena = enum {
    MEM_1,
    MEM_2,
};

pub const BumpAllocator = struct {
    const Self = @This();
    const Alignment = std.mem.Alignment;

    arena: Arena,
    ptr: [*]u8,
    start: [*]u8,
    end: [*]u8,

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

        return .{
            .arena = arena,
            .start = @ptrCast(lo),
            .ptr = @ptrCast(lo),
            .end = @ptrCast(hi),
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
            return null;
        }

        self.ptr = @ptrFromInt(new_p);
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
