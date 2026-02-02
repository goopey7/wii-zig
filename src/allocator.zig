const std = @import("std");
const c = @import("main.zig").c;
pub const BumpAllocator = @import("alloc/bump.zig").BumpAllocator;
pub const GeneralPurposeAllocator = @import("alloc/general_purpose.zig").GeneralPurposeAllocator;
pub const Arena = @import("alloc/arena.zig").Arena;
