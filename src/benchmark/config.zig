pub const BenchmarkConfig = struct {
    pub const AllocSizeRange = struct { min: usize, max: usize };
    pub const TimingMode = enum { per_allocation, per_frame };

    seeds: []const u64 = &.{ 42, 137, 2025, 8675309 },
    warmup_iterations: usize = 2,

    timing_mode: TimingMode = .per_allocation,

    // Frame workload
    frame_count: usize = 60,
    allocs_per_frame_range: AllocSizeRange = .{ .min = 20, .max = 150 },
    small_alloc_size_range: AllocSizeRange = .{
        .min = 64,
        .max = 1024,
    },

    // Mixed workload
    mixed_frame_count: usize = 10,
    mixed_alloc_size_range: AllocSizeRange = .{ .min = 16, .max = 4096 },
    object_lifetime_range: AllocSizeRange = .{ .min = 2, .max = 25 },
    initial_live_objects: usize = 3,

    // Stress workload
    stress_frame_count: usize = 200,
    stress_allocs_per_frame_range: AllocSizeRange = .{ .min = 50, .max = 100 },
    stress_alloc_size_range: AllocSizeRange = .{ .min = 16, .max = 32768 },
    stress_free_percent: usize = 50, // max percentage of live objects freed each frame
};
