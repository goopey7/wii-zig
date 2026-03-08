const std = @import("std");
const workloads = @import("workloads.zig");
const BenchmarkConfig = @import("config.zig").BenchmarkConfig;
const allocator = @import("common").allocator;
const ResultsReporter = @import("reporter.zig").ResultsReporter;
const http = @import("platform").http;
const dolphin = @import("platform").dolphin;
const c = @import("platform").c;

pub const CSV_HOST_DOLPHIN = "127.0.0.1";
pub const CSV_PORT_DOLPHIN: u16 = 3000;
pub const CSV_HOST = "192.168.0.108";
pub const CSV_PORT: u16 = 3000;

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

    const host = if (dolphin.isDolphin()) CSV_HOST_DOLPHIN else CSV_HOST;
    const port = if (dolphin.isDolphin()) CSV_PORT_DOLPHIN else CSV_PORT;
    var stream = try http.postStreaming(host, port, csv_size);
    defer stream.close();
    try reporter.writeCSVRows(&stream);
    try stream.flush();
    stream.close();
    std.log.info("CSV sent!", .{});
}
