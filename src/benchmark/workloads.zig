const std = @import("std");
const allocator = @import("common").allocator;
const BenchmarkConfig = @import("config.zig").BenchmarkConfig;
const common = @import("common");
const Timer = common.timer.Timer;
const Arena = common.allocator.Arena;

pub const AllocationRecord = struct {
    id: usize,
    frame_idx: usize,
    ptr: []u8,
    size: usize,
    actual_size: usize,
    alloc_time_ns: u64,
    free_time_ns: ?u64,
    arena: Arena,
    fragmentation: f64,
};

pub const WorkloadResult = struct {
    final_allocator_stats: allocator.Stats,
    allocations: std.ArrayList(AllocationRecord),
};

fn fragScore(stats: allocator.Stats) f64 {
    if (stats.total_capacity == 0) return 0.0;
    return 1.0 - @as(f64, @floatFromInt(stats.largest_free_block)) / @as(f64, @floatFromInt(stats.total_capacity));
}

/// Simulates a game running at a fixed frame rate.
/// Each frame allocates a variable number of small objects then frees them all.
/// Fragmentation is sampled after each frame's allocs and before their frees.
pub const FrameBasedWorkload = struct {
    pub fn run(config: BenchmarkConfig, alloc_interface: allocator.Interface, bench_alloc: std.mem.Allocator) !WorkloadResult {
        var prng = std.Random.DefaultPrng.init(42);
        const rand = prng.random();

        const max_allocs = config.frame_count * config.allocs_per_frame_range.max;
        var result = WorkloadResult{
            .final_allocator_stats = undefined,
            .allocations = try std.ArrayList(AllocationRecord).initCapacity(bench_alloc, max_allocs),
        };

        var std_alloc = alloc_interface.stdInterface();
        var alloc_id: usize = 0;

        for (0..config.frame_count) |frame_idx| {
            const frame_alloc_count = rand.intRangeAtMost(usize, config.allocs_per_frame_range.min, config.allocs_per_frame_range.max);
            const frame_start_idx = result.allocations.items.len;

            for (0..frame_alloc_count) |_| {
                const size = rand.intRangeAtMost(usize, config.small_alloc_size_range.min, config.small_alloc_size_range.max);
                var alloc_timer = Timer.start();
                const alloc_result = std_alloc.alloc(u8, size);
                alloc_timer.stop();
                if (alloc_result) |ptr| {
                    try result.allocations.append(bench_alloc, .{
                        .id = alloc_id,
                        .frame_idx = frame_idx,
                        .ptr = ptr[0..ptr.len],
                        .size = size,
                        .actual_size = ptr.len,
                        .alloc_time_ns = try alloc_timer.getTimeElapsed(.nanoseconds),
                        .arena = alloc_interface.getArena(),
                        .free_time_ns = null,
                        .fragmentation = fragScore(alloc_interface.getStats()),
                    });
                    alloc_id += 1;
                } else |_| {}
            }

            for (frame_start_idx..result.allocations.items.len) |i| {
                var free_timer = Timer.start();
                std_alloc.free(result.allocations.items[i].ptr);
                free_timer.stop();
                result.allocations.items[i].free_time_ns = try free_timer.getTimeElapsed(.nanoseconds);
            }
        }

        result.final_allocator_stats = alloc_interface.getStats();
        return result;
    }
};

/// Simulates a game with objects of varying lifetimes.
/// Short-lived and long-lived objects interleave on the heap, generating realistic fragmentation.
/// Fragmentation is sampled each frame after new allocations.
pub const MixedLifetimeWorkload = struct {
    const LiveObject = struct {
        ptr: []u8,
        death_frame: usize,
    };

    pub fn run(config: BenchmarkConfig, alloc_interface: allocator.Interface, bench_alloc: std.mem.Allocator) !WorkloadResult {
        var prng = std.Random.DefaultPrng.init(42);
        const rand = prng.random();

        const max_live = config.allocs_per_frame_range.max * config.object_lifetime_range.max;
        const max_allocs = config.mixed_frame_count * config.allocs_per_frame_range.max;

        var result = WorkloadResult{
            .final_allocator_stats = undefined,
            .allocations = try std.ArrayList(AllocationRecord).initCapacity(bench_alloc, max_allocs),
        };

        var live_objects = try std.ArrayList(LiveObject).initCapacity(bench_alloc, max_live);
        var std_alloc = alloc_interface.stdInterface();
        var alloc_id: usize = 0;

        // Seed with long-lived objects to simulate persistent level geometry.
        for (0..config.initial_live_objects) |_| {
            const size = rand.intRangeAtMost(usize, config.small_alloc_size_range.min, config.small_alloc_size_range.max);
            if (std_alloc.alloc(u8, size)) |ptr| {
                try live_objects.append(bench_alloc, .{ .ptr = ptr, .death_frame = config.mixed_frame_count });
            } else |_| {}
        }

        for (0..config.mixed_frame_count) |frame_idx| {
            // Free objects whose lifetime has expired this frame.
            var i: usize = 0;
            while (i < live_objects.items.len) {
                if (live_objects.items[i].death_frame == frame_idx) {
                    std_alloc.free(live_objects.items[i].ptr);
                    _ = live_objects.swapRemove(i);
                    // Don't advance i: swapRemove placed the last element at i.
                } else {
                    i += 1;
                }
            }

            // Allocate new objects with random sizes and lifetimes.
            const frame_alloc_count = rand.intRangeAtMost(usize, config.allocs_per_frame_range.min, config.allocs_per_frame_range.max);
            for (0..frame_alloc_count) |_| {
                const size = rand.intRangeAtMost(usize, config.small_alloc_size_range.min, config.small_alloc_size_range.max);
                const lifetime = rand.intRangeAtMost(usize, config.object_lifetime_range.min, config.object_lifetime_range.max);
                var alloc_timer = Timer.start();
                const alloc_result = std_alloc.alloc(u8, size);
                alloc_timer.stop();
                if (alloc_result) |ptr| {
                    const death_frame = @min(frame_idx + lifetime, config.mixed_frame_count);
                    try live_objects.append(bench_alloc, .{ .ptr = ptr, .death_frame = death_frame });
                    try result.allocations.append(bench_alloc, .{
                        .id = alloc_id,
                        .frame_idx = frame_idx,
                        .ptr = ptr,
                        .size = size,
                        .actual_size = ptr.len,
                        .alloc_time_ns = try alloc_timer.getTimeElapsed(.nanoseconds),
                        .arena = alloc_interface.getArena(),
                        .free_time_ns = null, // freed in a future frame
                        .fragmentation = fragScore(alloc_interface.getStats()),
                    });
                    alloc_id += 1;
                } else |_| {}
            }
        }

        // Cleanup remaining live objects (not recorded).
        for (live_objects.items) |obj| {
            std_alloc.free(obj.ptr);
        }

        result.final_allocator_stats = alloc_interface.getStats();
        return result;
    }
};
