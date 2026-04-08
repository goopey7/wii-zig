pub const BenchmarkConfig = struct {
    pub const AllocSizeRange = struct { min: usize, max: usize };
    pub const TimingMode = enum { per_allocation, per_frame };

    iterations: usize = 5,
    warmup_iterations: usize = 2,

    timing_mode: TimingMode = .per_allocation,

    // Frame-based workload
    frame_count: usize = 60,
    allocs_per_frame_range: AllocSizeRange = .{ .min = 20, .max = 150 },
    small_alloc_size_range: AllocSizeRange = .{
        .min = 64,
        .max = 1024,
    },

    // Mixed-lifetime workload
    mixed_frame_count: usize = 10,
    object_lifetime_range: AllocSizeRange = .{ .min = 2, .max = 25 },
    initial_live_objects: usize = 3,
};
