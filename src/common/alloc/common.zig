pub const c = @import("platform").c;
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
};
