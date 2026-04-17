const std = @import("std");
const workloads = @import("workloads.zig");
const BenchmarkConfig = @import("config.zig").BenchmarkConfig;
const allocator = @import("common").allocator;
const tracy = @import("common").tracy;
const ResultsReporter = @import("reporter.zig").ResultsReporter;
const http = @import("platform").http;
const dolphin = @import("platform").dolphin;
const c = @import("platform").c;

pub const CSV_HOST_DOLPHIN = "127.0.0.1";
pub const CSV_PORT_DOLPHIN: u16 = 3000;
pub const CSV_HOST = "192.168.0.107";
pub const CSV_PORT: u16 = 3000;

pub fn main() !void {
    std.log.info("Benchmark starting", .{});
    if (tracy.enabled) {
        std.log.info("Waiting for Tracy connection (15s timeout)...", .{});
        if (tracy.waitForConnection(15_000)) {
            std.log.info("Tracy connected.", .{});
        } else {
            std.log.info("Tracy not connected, running without.", .{});
        }
    }
    const config = BenchmarkConfig{};

    // Use MEM_2 for benchmark data so test allocators have all of MEM_1.
    var bench_alloc = try allocator.BumpAllocator.init(.MEM_2, 1024 * 1024 * 20);
    var panic_bench = allocator.PanicAllocator{ .inner = bench_alloc.interface().stdInterface() };
    const bench = panic_bench.allocator();
    var reporter = try ResultsReporter.init(bench, 100);
    defer reporter.deinit();

    std.log.info("Warming up ({} iterations)...", .{config.warmup_iterations});
    for (0..config.warmup_iterations) |_| {
        {
            var tlsf = try allocator.TlsfAllocator.init(.MEM_1, null);
            const z = tracy.zoneBegin("wu_tlsf_frame", @src());
            _ = try workloads.FrameBasedWorkload.run(config, tlsf.interface(), bench, 42);
            tracy.zoneEnd(z);
            tlsf.deinit();
            tracy.frameMarkFlush();
        }
        {
            var fl = try allocator.FreeListAllocator.init(.MEM_1, null);
            const z = tracy.zoneBegin("wu_fl_frame", @src());
            _ = try workloads.FrameBasedWorkload.run(config, fl.interface(), bench, 42);
            tracy.zoneEnd(z);
            fl.deinit();
            tracy.frameMarkFlush();
        }
        {
            var bump = try allocator.BumpAllocator.init(.MEM_1, null);
            const z = tracy.zoneBegin("wu_bump_frame", @src());
            _ = try workloads.FrameBasedWorkload.run(config, bump.interface(), bench, 42);
            tracy.zoneEnd(z);
            bump.deinit();
            tracy.frameMarkFlush();
        }
        {
            var libc = allocator.LibcAllocator.init();
            const z = tracy.zoneBegin("wu_libc_frame", @src());
            _ = try workloads.FrameBasedWorkload.run(config, libc.interface(), bench, 42);
            tracy.zoneEnd(z);
            libc.deinit();
            tracy.frameMarkFlush();
        }
        {
            var tlsf_sw = try allocator.TlsfAllocator.init(.MEM_1, null);
            const z = tracy.zoneBegin("wu_tlsf_stress", @src());
            _ = try workloads.StressWorkload.run(config, tlsf_sw.interface(), bench, 42);
            tracy.zoneEnd(z);
            tlsf_sw.deinit();
            tracy.frameMarkFlush();
        }
        {
            var libc_sw = allocator.LibcAllocator.init();
            const z = tracy.zoneBegin("wu_libc_stress", @src());
            _ = try workloads.StressWorkload.run(config, libc_sw.interface(), bench, 42);
            tracy.zoneEnd(z);
            libc_sw.deinit();
            tracy.frameMarkFlush();
        }
    }
    reporter.deinit();
    bench_alloc.reset();
    reporter = try ResultsReporter.init(bench, 100);

    std.log.info("Running {} seeds...", .{config.seeds.len});
    for (config.seeds) |seed| {
        const bench_remaining = @intFromPtr(bench_alloc.end) - @intFromPtr(bench_alloc.ptr);
        const mem1_remaining = @intFromPtr(c.SYS_GetArena1Hi()) - @intFromPtr(c.SYS_GetArena1Lo());
        std.log.info("Seed {}... (remaining benchmark memory: {} B, MEM1 remaining: {} B)", .{ seed, bench_remaining, mem1_remaining });

        std.log.info("tlsf/frame", .{});
        {
            var tlsf = try allocator.TlsfAllocator.init(.MEM_1, null);
            const zone = tracy.zoneBegin("tlsf_frame", @src());
            const tlsf_frame = try workloads.FrameBasedWorkload.run(config, tlsf.interface(), bench, seed);
            tracy.zoneEnd(zone);
            tlsf.deinit();
            try reporter.addResult("tlsf_frame", seed, tlsf_frame);
            tracy.frameMarkFlush();
        }

        std.log.info("free_list/frame", .{});
        {
            var fl = try allocator.FreeListAllocator.init(.MEM_1, null);
            const zone = tracy.zoneBegin("free_list_frame", @src());
            const fl_frame = try workloads.FrameBasedWorkload.run(config, fl.interface(), bench, seed);
            tracy.zoneEnd(zone);
            fl.deinit();
            try reporter.addResult("free_list_frame", seed, fl_frame);
            tracy.frameMarkFlush();
        }

        std.log.info("bump/frame", .{});
        {
            var bump_frame_alloc = try allocator.BumpAllocator.init(.MEM_1, null);
            const zone = tracy.zoneBegin("bump_frame", @src());
            const bump_frame = try workloads.FrameBasedWorkload.run(config, bump_frame_alloc.interface(), bench, seed);
            tracy.zoneEnd(zone);
            bump_frame_alloc.deinit();
            try reporter.addResult("bump_frame", seed, bump_frame);
            tracy.frameMarkFlush();
        }

        std.log.info("tlsf/mixed", .{});
        {
            var tlsf_m = try allocator.TlsfAllocator.init(.MEM_1, null);
            const zone = tracy.zoneBegin("tlsf_mixed", @src());
            const tlsf_mixed = try workloads.MixedLifetimeWorkload.run(config, tlsf_m.interface(), bench, seed);
            tracy.zoneEnd(zone);
            tlsf_m.deinit();
            try reporter.addResult("tlsf_mixed", seed, tlsf_mixed);
            tracy.frameMarkFlush();
        }

        std.log.info("free_list/mixed", .{});
        {
            var fl_m = try allocator.FreeListAllocator.init(.MEM_1, null);
            const zone = tracy.zoneBegin("free_list_mixed", @src());
            const fl_mixed = try workloads.MixedLifetimeWorkload.run(config, fl_m.interface(), bench, seed);
            tracy.zoneEnd(zone);
            fl_m.deinit();
            try reporter.addResult("free_list_mixed", seed, fl_mixed);
            tracy.frameMarkFlush();
        }

        std.log.info("bump/mixed", .{});
        {
            var bump_m = try allocator.BumpAllocator.init(.MEM_1, null);
            const zone = tracy.zoneBegin("bump_mixed", @src());
            const bump_mixed = try workloads.MixedLifetimeWorkload.run(config, bump_m.interface(), bench, seed);
            tracy.zoneEnd(zone);
            bump_m.deinit();
            try reporter.addResult("bump_mixed", seed, bump_mixed);
            tracy.frameMarkFlush();
        }

        std.log.info("libc/frame", .{});
        {
            var libc_frame = allocator.LibcAllocator.init();
            const zone = tracy.zoneBegin("libc_frame", @src());
            const libc_frame_result = try workloads.FrameBasedWorkload.run(config, libc_frame.interface(), bench, seed);
            tracy.zoneEnd(zone);
            libc_frame.deinit();
            try reporter.addResult("libc_frame", seed, libc_frame_result);
            tracy.frameMarkFlush();
        }

        std.log.info("libc/mixed", .{});
        {
            var libc_m = allocator.LibcAllocator.init();
            const zone = tracy.zoneBegin("libc_mixed", @src());
            const libc_mixed = try workloads.MixedLifetimeWorkload.run(config, libc_m.interface(), bench, seed);
            tracy.zoneEnd(zone);
            libc_m.deinit();
            try reporter.addResult("libc_mixed", seed, libc_mixed);
            tracy.frameMarkFlush();
        }

        std.log.info("tlsf/stress", .{});
        {
            var tlsf_s = try allocator.TlsfAllocator.init(.MEM_1, null);
            const zone = tracy.zoneBegin("tlsf_stress", @src());
            const tlsf_stress = try workloads.StressWorkload.run(config, tlsf_s.interface(), bench, seed);
            tracy.zoneEnd(zone);
            tlsf_s.deinit();
            try reporter.addStressResult("tlsf_stress", seed, tlsf_stress);
            tracy.frameMarkFlush();
        }

        std.log.info("libc/stress", .{});
        {
            var libc_s = allocator.LibcAllocator.init();
            const zone = tracy.zoneBegin("libc_stress", @src());
            const libc_stress = try workloads.StressWorkload.run(config, libc_s.interface(), bench, seed);
            tracy.zoneEnd(zone);
            libc_s.deinit();
            try reporter.addStressResult("libc_stress", seed, libc_stress);
            tracy.frameMarkFlush();
        }
    }

    std.log.info("Benchmark complete", .{});

    const csv_size = blk: {
        const z = tracy.zoneBegin("csv_size_calc", @src());
        const sz = reporter.totalCSVSize();
        tracy.zoneEnd(z);
        break :blk sz;
    };
    std.log.info("CSV size: {} bytes", .{csv_size});

    const host = if (dolphin.isDolphin()) CSV_HOST_DOLPHIN else CSV_HOST;
    const port = if (dolphin.isDolphin()) CSV_PORT_DOLPHIN else CSV_PORT;
    std.log.info("Sending CSV to {}:{}...", .{ host, port });
    {
        const z = tracy.zoneBegin("csv_send", @src());
        var stream = try http.postStreaming(host, port, csv_size);
        defer stream.close();
        try reporter.writeCSVRows(&stream);
        try stream.flush();
        stream.close();
        tracy.zoneEnd(z);
    }
    std.log.info("CSV sent!", .{});
}
