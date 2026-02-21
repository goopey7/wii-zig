const std = @import("std");
const allocator = @import("common").allocator;
const BenchmarkConfig = @import("config.zig").BenchmarkConfig;
const Timer = @import("common").timer.Timer;

pub const WorkloadResult = struct {
    total_alloc_time_us: u64,
    total_free_time_us: u64,
    frame_alloc_times: []u64,
    frame_free_times: []u64,
    allocation_count: usize,
    failure_count: usize,
    final_allocator_stats: allocator.Stats,
};

pub const FrameBasedWorkload = struct {
    const Allocation = struct {
        ptr: []u8,
        size: usize,
    };

    pub fn run(comptime timing_mode: BenchmarkConfig.TimingMode, config: BenchmarkConfig, alloc_interface: allocator.Interface, bench_alloc: std.mem.Allocator) !WorkloadResult {
        var prng = std.Random.DefaultPrng.init(42);
        const rand = prng.random();

        var result = WorkloadResult{
            .total_alloc_time_us = 0,
            .total_free_time_us = 0,
            .allocation_count = 0,
            .failure_count = 0,
            .final_allocator_stats = undefined,
            .frame_alloc_times = undefined,
            .frame_free_times = undefined,
        };

        var std_alloc = alloc_interface.stdInterface();
        var allocations = try std.ArrayList(Allocation).initCapacity(bench_alloc, config.small_allocs_per_frame);
        defer allocations.deinit(bench_alloc);

        for (0..config.frame_count) |_| {
            allocations.clearRetainingCapacity();

            if (timing_mode == .per_allocation) {
                for (0..config.small_allocs_per_frame) |_| {
                    const range = config.small_alloc_size_range;
                    const size = rand.intRangeAtMost(usize, range.min, range.max);
                    var alloc_timer = Timer.start();
                    const alloc_result = std_alloc.alloc(u8, size);
                    alloc_timer.stop();
                    if (alloc_result) |ptr| {
                        result.total_alloc_time_us += try alloc_timer.getTimeElapsed(.microseconds);
                        result.allocation_count += 1;
                        try allocations.append(bench_alloc, .{ .ptr = ptr[0..size], .size = size });
                    } else |_| {
                        result.failure_count += 1;
                    }
                }

                var free_timer = Timer.start();
                for (allocations.items) |allocation| {
                    std_alloc.free(allocation.ptr);
                }
                free_timer.stop();
                result.total_free_time_us += try free_timer.getTimeElapsed(.microseconds);
                allocations.clearAndFree(bench_alloc);
                result.final_allocator_stats = alloc_interface.getStats();
            } else {
                for (0..config.small_allocs_per_frame) |_| {
                    const range = config.small_alloc_size_range;
                    const size = rand.intRangeAtMost(usize, range.min, range.max);
                    if (std_alloc.alloc(u8, size)) |ptr| {
                        result.allocation_count += 1;
                        try allocations.append(bench_alloc, .{ .ptr = ptr[0..size], .size = size });
                    } else |_| {
                        result.failure_count += 1;
                    }
                }

                for (allocations.items) |allocation| {
                    std_alloc.free(allocation.ptr);
                }
                allocations.clearAndFree(bench_alloc);
                result.final_allocator_stats = alloc_interface.getStats();
            }
        }
        return result;
    }
};
