pub const BenchmarkConfig = struct {
    pub const AllocSizeRange = struct { min: usize, max: usize };
    pub const TimingMode = enum { per_allocation, per_frame };

    iterations: usize = 5,
    warmup_iterations: usize = 2,

    timing_mode: TimingMode = .per_allocation,

    frame_count: usize = 60,
    small_allocs_per_frame: usize = 100,
    small_alloc_size_range: AllocSizeRange = .{
        .min = 64,
        .max = 1024,
    },

    resource_sizes: []const usize = &[_]usize{ 4096, 16384, 65536, 262144 },
    resource_count_per_level: usize = 50,

    allocation_ratio: struct { small: f32, medium: f32, large: f32 } = .{
        .small = 0.7,
        .medium = 0.2,
        .large = 0.1,
    },
    object_lifetime_range: struct { min: usize, max: usize } = .{
        .min = 10,
        .max = 300,
    },

    target_utilization: f32 = 0.85,
    pressure_cycles: usize = 1000,

    enabled_tests: struct {
        frame_based: bool,
        resource_load: bool,
        mixed_workload: bool,
        memory_pressure: bool,
    } = .{
        .frame_based = true,
        .resource_load = true,
        .mixed_workload = true,
        .memory_pressure = true,
    },
};
