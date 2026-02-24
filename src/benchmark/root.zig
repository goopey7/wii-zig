const std = @import("std");
const workloads = @import("workloads.zig");
const BenchmarkConfig = @import("config.zig").BenchmarkConfig;
const allocator = @import("common").allocator;
const ResultsReporter = @import("reporter.zig").ResultsReporter;
const http = @import("platform").http;

pub fn main() !void {
    std.log.info("Benchmark starting", .{});
    const config = BenchmarkConfig{};

    var bench_alloc = try allocator.BumpAllocator.init(.MEM_1, 1024 * 6000);
    var reporter = try ResultsReporter.init(bench_alloc.interface().stdInterface(), 100);
    defer reporter.deinit();

    for (0..config.iterations) |_| {
        var gpa = try allocator.BumpAllocator.init(.MEM_1, null);
        defer gpa.deinit();
        const result = try workloads.FrameBasedWorkload.run(.per_allocation, config, gpa.interface(), bench_alloc.interface().stdInterface());
        try reporter.addResult("gpa", result);
    }

    std.log.info("Benchmark complete", .{});

    const csv_size = reporter.totalCSVSize();
    std.log.info("CSV size: {} bytes", .{csv_size});

    var stream = try http.postStreaming("192.168.0.106", 3000, csv_size);
    defer stream.close();
    try reporter.writeCSVRows(&stream);
    try stream.flush();
    stream.close();
    std.log.info("CSV sent!", .{});
}
