const std = @import("std");
const WorkloadResult = @import("workloads.zig").WorkloadResult;

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
};
