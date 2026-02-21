const std = @import("std");
const workloads = @import("workloads.zig");
const BenchmarkConfig = @import("config.zig").BenchmarkConfig;
const allocator = @import("common").allocator;
const ResultsReporter = @import("reporter.zig").ResultsReporter;

pub fn main() !void {
    std.log.info("Benchmark starting", .{});
    const config = BenchmarkConfig{};

    var bench_alloc = try allocator.BumpAllocator.init(.MEM_1, 1024 * 6000);
    var reporter = try ResultsReporter.init(bench_alloc.interface().stdInterface(), 100);
    defer reporter.deinit();

    for (0..config.iterations) |_| {
        var gpa = try allocator.GeneralPurposeAllocator.init(.MEM_1, null);
        defer gpa.deinit();
        const result = try workloads.FrameBasedWorkload.run(.per_allocation, config, gpa.interface(), bench_alloc.interface().stdInterface());
        try reporter.addResult("gpa", result);
    }

    std.log.info("Benchmark complete", .{});
    reporter.printComparison();
}
