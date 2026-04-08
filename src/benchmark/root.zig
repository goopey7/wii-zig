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

    // Use MEM_2 for benchmark data so test allocators have all of MEM_1.
    var bench_alloc = try allocator.BumpAllocator.init(.MEM_2, 1024 * 1024 * 20);
    var reporter = try ResultsReporter.init(bench_alloc.interface().stdInterface(), 100);
    defer reporter.deinit();

    // Warmup: prime caches without recording results.
    std.log.info("Warming up ({} iterations)...", .{config.warmup_iterations});
    for (0..config.warmup_iterations) |_| {
        var tlsf = try allocator.TlsfAllocator.init(.MEM_1, 1024 * 1024 * 16);
        _ = try workloads.FrameBasedWorkload.run(config, tlsf.interface(), bench_alloc.interface().stdInterface());
        tlsf.deinit();

        var fl = try allocator.FreeListAllocator.init(.MEM_1, null);
        _ = try workloads.FrameBasedWorkload.run(config, fl.interface(), bench_alloc.interface().stdInterface());
        fl.deinit();

        var bump = try allocator.BumpAllocator.init(.MEM_1, 1024 * 1024 * 8);
        _ = try workloads.FrameBasedWorkload.run(config, bump.interface(), bench_alloc.interface().stdInterface());
        bump.deinit();
    }

    // Measured iterations.
    std.log.info("Running {} measured iterations...", .{config.iterations});
    for (0..config.iterations) |_| {
        var tlsf = try allocator.TlsfAllocator.init(.MEM_1, null);
        const tlsf_frame = try workloads.FrameBasedWorkload.run(config, tlsf.interface(), bench_alloc.interface().stdInterface());
        tlsf.deinit();
        try reporter.addResult("tlsf_frame", tlsf_frame);

        var fl = try allocator.FreeListAllocator.init(.MEM_1, null);
        const fl_frame = try workloads.FrameBasedWorkload.run(config, fl.interface(), bench_alloc.interface().stdInterface());
        fl.deinit();
        try reporter.addResult("free_list_frame", fl_frame);

        var bump_frame_alloc = try allocator.BumpAllocator.init(.MEM_1, 1024 * 1024 * 8);
        const bump_frame = try workloads.FrameBasedWorkload.run(config, bump_frame_alloc.interface(), bench_alloc.interface().stdInterface());
        bump_frame_alloc.deinit();
        try reporter.addResult("bump_frame", bump_frame);

        var tlsf_m = try allocator.TlsfAllocator.init(.MEM_1, null);
        const tlsf_mixed = try workloads.MixedLifetimeWorkload.run(config, tlsf_m.interface(), bench_alloc.interface().stdInterface());
        tlsf_m.deinit();
        try reporter.addResult("tlsf_mixed", tlsf_mixed);

        var fl_m = try allocator.FreeListAllocator.init(.MEM_1, 1024 * 1024 * 8);
        const fl_mixed = try workloads.MixedLifetimeWorkload.run(config, fl_m.interface(), bench_alloc.interface().stdInterface());
        fl_m.deinit();
        try reporter.addResult("free_list_mixed", fl_mixed);

        var bump_m = try allocator.BumpAllocator.init(.MEM_1, 1024 * 1024 * 8);
        const bump_mixed = try workloads.MixedLifetimeWorkload.run(config, bump_m.interface(), bench_alloc.interface().stdInterface());
        bump_m.deinit();
        try reporter.addResult("bump_mixed", bump_mixed);
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
