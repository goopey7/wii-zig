const std = @import("std");
const WorkloadResult = @import("workloads.zig").WorkloadResult;
const Arena = @import("common").allocator.Arena;

const CSV_HEADER = "workload_name,id,size,actual_size,alloc_time_us,free_time_us,arena\n";

pub const ResultsReporter = struct {
    const NamedResult = struct {
        name: []const u8,
        result: WorkloadResult,
    };

    results: std.ArrayList(NamedResult),
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, capacity: usize) !ResultsReporter {
        return .{
            .results = try std.ArrayList(NamedResult).initCapacity(alloc, capacity),
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *ResultsReporter) void {
        self.results.deinit(self.alloc);
    }

    pub fn addResult(self: *ResultsReporter, name: []const u8, result: WorkloadResult) !void {
        try self.results.append(self.alloc, .{
            .name = name,
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
                total += intLen(alloc.id) + 1;
                total += intLen(alloc.size) + 1;
                total += intLen(alloc.actual_size) + 1;
                total += intLen(alloc.alloc_time_us) + 1;
                total += intLen(alloc.free_time_us.?) + 1;
                total += std.enums.tagName(Arena, alloc.arena).?.len + 1;
            }
        }
        return total;
    }

    pub fn writeCSVRows(self: *ResultsReporter, writer: anytype) !void {
        const w = writer;

        try w.writeAll(CSV_HEADER);

        for (self.results.items) |named_result| {
            for (named_result.result.allocations.items) |alloc| {
                try w.writeAll(named_result.name);
                try w.writeByte(',');
                try w.print("{d},", .{alloc.id});
                try w.print("{d},", .{alloc.size});
                try w.print("{d},", .{alloc.actual_size});
                try w.print("{d},", .{alloc.alloc_time_us});
                try w.print("{d},", .{alloc.free_time_us.?});
                try w.writeAll(std.enums.tagName(Arena, alloc.arena).?);
                try w.writeByte('\n');
            }
        }
    }
};
