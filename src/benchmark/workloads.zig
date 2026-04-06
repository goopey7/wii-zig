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
    alloc_time_ns: u64,
    free_time_ns: ?u64,
    arena: Arena,
};

pub const WorkloadResult = struct {
    final_allocator_stats: allocator.Stats,
    fragmentation_score: f64,
    allocations: std.ArrayList(AllocationRecord),
};

pub const FrameBasedWorkload = struct {
    pub fn run(comptime timing_mode: BenchmarkConfig.TimingMode, config: BenchmarkConfig, alloc_interface: allocator.Interface, bench_alloc: std.mem.Allocator) !WorkloadResult {
        var prng = std.Random.DefaultPrng.init(42);
        const rand = prng.random();

        var result = WorkloadResult{
            .final_allocator_stats = undefined,
            .fragmentation_score = 0.0,
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
                            .alloc_time_ns = try alloc_timer.getTimeElapsed(.nanoseconds),
                            .arena = alloc_interface.getArena(),
                            .free_time_ns = null,
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
                    result.allocations.items[i].free_time_ns = try free_timer.getTimeElapsed(.nanoseconds);
                }
            }
        }
        const final_stats = alloc_interface.getStats();
        result.final_allocator_stats = final_stats;
        if (final_stats.total_capacity > 0) {
            result.fragmentation_score = 1.0 - @as(f64, @floatFromInt(final_stats.largest_free_block)) / @as(f64, @floatFromInt(final_stats.total_capacity));
        }
        return result;
    }
};
