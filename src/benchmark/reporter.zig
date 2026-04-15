const std = @import("std");
const workloads = @import("workloads.zig");
const WorkloadResult = workloads.WorkloadResult;
const StressWorkloadResult = workloads.StressWorkloadResult;
const Arena = @import("common").allocator.Arena;

const CSV_HEADER = "workload_name,seed,frame_idx,id,size,actual_size,overhead_bytes,alloc_time_ns,free_time_ns,arena,fragmentation,internal_fragmentation\n";
const STATS_HEADER = "workload_name,seed,peak_usage,peak_header_overhead,fixed_overhead,total_capacity,alloc_count,free_count,alloc_failures\n";
const STRESS_HEADER = "stress_workload_name,seed,frame_idx,mean_alloc_time_ns,max_alloc_time_ns,mean_free_time_ns,fragmentation,internal_fragmentation,live_bytes,alloc_count,free_count\n";
const STRESS_STATS_HEADER = "stress_workload_name,seed,peak_usage,peak_header_overhead,fixed_overhead,total_capacity,alloc_count,free_count,alloc_failures\n";

pub const ResultsReporter = struct {
    const NamedResult = struct {
        name: []const u8,
        seed: u64,
        result: WorkloadResult,
    };

    const NamedStressResult = struct {
        name: []const u8,
        seed: u64,
        result: StressWorkloadResult,
    };

    results: std.ArrayList(NamedResult),
    stress_results: std.ArrayList(NamedStressResult),
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, capacity: usize) !ResultsReporter {
        return .{
            .results = try std.ArrayList(NamedResult).initCapacity(alloc, capacity),
            .stress_results = try std.ArrayList(NamedStressResult).initCapacity(alloc, capacity),
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *ResultsReporter) void {
        self.results.deinit(self.alloc);
        self.stress_results.deinit(self.alloc);
    }

    pub fn addResult(self: *ResultsReporter, name: []const u8, seed: u64, result: WorkloadResult) !void {
        try self.results.append(self.alloc, .{
            .name = name,
            .seed = seed,
            .result = result,
        });
    }

    pub fn addStressResult(self: *ResultsReporter, name: []const u8, seed: u64, result: StressWorkloadResult) !void {
        try self.stress_results.append(self.alloc, .{
            .name = name,
            .seed = seed,
            .result = result,
        });
    }

    fn intLen(n: anytype) usize {
        var x = n;
        var len: usize = 1;
        while (x >= 10) {
            x /= 10;
            len += 1;
        }
        return len;
    }

    pub fn totalCSVSize(self: *ResultsReporter) usize {
        var total: usize = 0;
        total += CSV_HEADER.len;

        for (self.results.items) |named_result| {
            for (named_result.result.allocations.items) |alloc| {
                total += named_result.name.len + 1;
                total += intLen(alloc.seed) + 1;
                total += intLen(alloc.frame_idx) + 1;
                total += intLen(alloc.id) + 1;
                total += intLen(alloc.size) + 1;
                total += intLen(alloc.actual_size) + 1;
                total += intLen(alloc.overhead_bytes) + 1;
                total += intLen(alloc.alloc_time_ns) + 1;
                total += intLen(alloc.free_time_ns orelse 0) + 1;
                total += std.enums.tagName(Arena, alloc.arena).?.len + 1;
                const frag_int = @as(u32, @intFromFloat(alloc.fragmentation * 1000000.0));
                total += intLen(frag_int / 1000000) + 1 + 6 + 1;
                const int_frag_int = @as(u32, @intFromFloat(alloc.internal_fragmentation * 1000000.0));
                // int digits + decimal + decimal digits + newline
                total += intLen(int_frag_int / 1000000) + 1 + 6 + 1;
            }
        }

        total += STATS_HEADER.len;
        for (self.results.items) |named_result| {
            const s = named_result.result.final_allocator_stats;
            total += named_result.name.len + 1;
            total += intLen(named_result.seed) + 1;
            total += intLen(s.peak_usage) + 1;
            total += intLen(s.peak_header_overhead) + 1;
            total += intLen(s.fixed_overhead) + 1;
            total += intLen(s.total_capacity) + 1;
            total += intLen(s.alloc_count) + 1;
            total += intLen(s.free_count) + 1;
            total += intLen(s.alloc_failures) + 1;
        }

        total += STRESS_HEADER.len;
        for (self.stress_results.items) |named| {
            for (named.result.frames.items) |frame| {
                total += named.name.len + 1;
                total += intLen(frame.seed) + 1;
                total += intLen(frame.frame_idx) + 1;
                total += intLen(frame.mean_alloc_time_ns) + 1;
                total += intLen(frame.max_alloc_time_ns) + 1;
                total += intLen(frame.mean_free_time_ns) + 1;
                const frag_int = @as(u32, @intFromFloat(frame.fragmentation * 1000000.0));
                total += intLen(frag_int / 1000000) + 1 + 6 + 1;
                const int_frag_int = @as(u32, @intFromFloat(frame.internal_fragmentation * 1000000.0));
                total += intLen(int_frag_int / 1000000) + 1 + 6 + 1;
                total += intLen(frame.live_bytes) + 1;
                total += intLen(frame.alloc_count) + 1;
                total += intLen(frame.free_count) + 1;
            }
        }

        total += STRESS_STATS_HEADER.len;
        for (self.stress_results.items) |named| {
            const s = named.result.final_allocator_stats;
            total += named.name.len + 1;
            total += intLen(named.seed) + 1;
            total += intLen(s.peak_usage) + 1;
            total += intLen(s.peak_header_overhead) + 1;
            total += intLen(s.fixed_overhead) + 1;
            total += intLen(s.total_capacity) + 1;
            total += intLen(s.alloc_count) + 1;
            total += intLen(s.free_count) + 1;
            total += intLen(s.alloc_failures) + 1;
        }

        return total;
    }

    pub fn writeCSVRows(self: *ResultsReporter, writer: anytype) !void {
        const w = writer;

        try w.writeAll(CSV_HEADER);

        for (self.results.items) |named_result| {
            for (named_result.result.allocations.items) |alloc| {
                try w.writeAll(named_result.name);
                try w.print(",{d},", .{alloc.seed});
                try w.print("{d},", .{alloc.frame_idx});
                try w.print("{d},", .{alloc.id});
                try w.print("{d},", .{alloc.size});
                try w.print("{d},", .{alloc.actual_size});
                try w.print("{d},", .{alloc.overhead_bytes});
                try w.print("{d},", .{alloc.alloc_time_ns});
                try w.print("{d},", .{alloc.free_time_ns orelse 0});
                try w.writeAll(std.enums.tagName(Arena, alloc.arena).?);
                try w.writeByte(',');
                // can't format floats cuz the standard library tries to use 128 bit float stuff
                const frag_int = @as(u32, @intFromFloat(alloc.fragmentation * 1000000.0));
                try w.print("{d}.{d:0>6}", .{ frag_int / 1000000, frag_int % 1000000 });
                const int_frag_int = @as(u32, @intFromFloat(alloc.internal_fragmentation * 1000000.0));
                try w.print(",{d}.{d:0>6}", .{ int_frag_int / 1000000, int_frag_int % 1000000 });
                try w.writeByte('\n');
            }
        }

        try w.writeAll(STATS_HEADER);
        for (self.results.items) |named_result| {
            const s = named_result.result.final_allocator_stats;
            try w.writeAll(named_result.name);
            try w.print(",{d},{d},{d},{d},{d},{d},{d},{d}\n", .{
                named_result.seed,
                s.peak_usage,
                s.peak_header_overhead,
                s.fixed_overhead,
                s.total_capacity,
                s.alloc_count,
                s.free_count,
                s.alloc_failures,
            });
        }

        try w.writeAll(STRESS_HEADER);
        for (self.stress_results.items) |named| {
            for (named.result.frames.items) |frame| {
                try w.writeAll(named.name);
                try w.print(",{d},{d},{d},{d},{d},", .{
                    frame.seed,
                    frame.frame_idx,
                    frame.mean_alloc_time_ns,
                    frame.max_alloc_time_ns,
                    frame.mean_free_time_ns,
                });
                const frag_int = @as(u32, @intFromFloat(frame.fragmentation * 1000000.0));
                try w.print("{d}.{d:0>6},", .{ frag_int / 1000000, frag_int % 1000000 });
                const int_frag_int = @as(u32, @intFromFloat(frame.internal_fragmentation * 1000000.0));
                try w.print("{d}.{d:0>6},", .{ int_frag_int / 1000000, int_frag_int % 1000000 });
                try w.print("{d},{d},{d}\n", .{
                    frame.live_bytes,
                    frame.alloc_count,
                    frame.free_count,
                });
            }
        }

        try w.writeAll(STRESS_STATS_HEADER);
        for (self.stress_results.items) |named| {
            const s = named.result.final_allocator_stats;
            try w.writeAll(named.name);
            try w.print(",{d},{d},{d},{d},{d},{d},{d},{d}\n", .{
                named.seed,
                s.peak_usage,
                s.peak_header_overhead,
                s.fixed_overhead,
                s.total_capacity,
                s.alloc_count,
                s.free_count,
                s.alloc_failures,
            });
        }
    }
};
