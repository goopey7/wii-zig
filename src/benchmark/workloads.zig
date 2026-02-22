const std = @import("std");
const allocator = @import("common").allocator;
const BenchmarkConfig = @import("config.zig").BenchmarkConfig;
const common = @import("common");
const Timer = common.timer.Timer;
const Arena = common.allocator.Arena;

const AllocationRecord = struct {
    id: usize,
    ptr: []u8,
    size: usize,
    actual_size: usize,
    alloc_time_us: u64,
    free_time_us: ?u64,
    arena: Arena,
};

pub const WorkloadResult = struct {
    final_allocator_stats: allocator.Stats,
    allocations: std.ArrayList(AllocationRecord),
};

pub const FrameBasedWorkload = struct {
    pub fn run(comptime timing_mode: BenchmarkConfig.TimingMode, config: BenchmarkConfig, alloc_interface: allocator.Interface, bench_alloc: std.mem.Allocator) !WorkloadResult {
        var prng = std.Random.DefaultPrng.init(42);
        const rand = prng.random();

        var result = WorkloadResult{
            .final_allocator_stats = undefined,
            .allocations = try std.ArrayList(AllocationRecord).initCapacity(bench_alloc, 6000),
        };

        var std_alloc = alloc_interface.stdInterface();

        for (0..config.frame_count) |frame_idx| {
            if (timing_mode == .per_allocation) {
                for (0..config.small_allocs_per_frame) |idx| {
                    const range = config.small_alloc_size_range;
                    const size = rand.intRangeAtMost(usize, range.min, range.max);
                    var alloc_timer = Timer.start();
                    const alloc_result = std_alloc.alloc(u8, size);
                    alloc_timer.stop();
                    if (alloc_result) |ptr| {
                        const allocation: AllocationRecord = .{
                            .id = frame_idx * config.small_allocs_per_frame + idx,
                            .ptr = ptr[0..ptr.len],
                            .size = size,
                            .actual_size = ptr.len,
                            .alloc_time_us = try alloc_timer.getTimeElapsed(.microseconds),
                            .arena = alloc_interface.getArena(),
                            .free_time_us = null,
                        };
                        try result.allocations.append(bench_alloc, allocation);
                    } else |_| {}
                }

                const frame_start = frame_idx * config.small_allocs_per_frame;
                const frame_end = frame_start + config.small_allocs_per_frame;
                for (frame_start..frame_end) |i| {
                    var free_timer = Timer.start();
                    std_alloc.free(result.allocations.items[i].ptr);
                    free_timer.stop();
                    result.allocations.items[i].free_time_us = try free_timer.getTimeElapsed(.microseconds);
                }
            }
        }
        result.final_allocator_stats = alloc_interface.getStats();
        return result;
    }
};
