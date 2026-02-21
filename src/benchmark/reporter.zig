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

    pub fn printComparison(self: *ResultsReporter) void {
        if (self.results.items.len == 0) {
            std.log.info("No results to display.", .{});
            return;
        }

        const col_width: usize = 14;
        const metric_width: usize = 28;

        self.printSeparator(metric_width, col_width);
        self.printHeader(metric_width, col_width);
        self.printSeparator(metric_width, col_width);

        self.printCountRow("Allocations", "allocation_count", metric_width, col_width);
        self.printCountRow("Failures", "failure_count", metric_width, col_width);

        self.printSeparator(metric_width, col_width);

        self.printTimeRow("Total Alloc Time (us)", "alloc", metric_width, col_width);
        self.printTimeRow("Total Free Time (us)", "free", metric_width, col_width);

        self.printSeparator(metric_width, col_width);

        self.printBytesRow("Capacity (KB)", "capacity", metric_width, col_width);
        self.printBytesRow("Peak Usage (KB)", "peak", metric_width, col_width);
        self.printBytesRow("Final Usage (KB)", "used", metric_width, col_width);

        self.printSeparator(metric_width, col_width);

        self.printStatsCountRow("Alloc Calls", "alloc_count", metric_width, col_width);
        self.printStatsCountRow("Free Calls", "free_count", metric_width, col_width);
        self.printStatsCountRow("Alloc Failures", "alloc_failures", metric_width, col_width);

        self.printSeparator(metric_width, col_width);
    }

    fn printSeparator(self: *ResultsReporter, metric_width: usize, col_width: usize) void {
        var line: [256]u8 = undefined;
        var idx: usize = 0;

        idx += self.appendStr(line[idx..], "+");
        idx += self.appendChar(line[idx..], '-', metric_width);
        idx += self.appendStr(line[idx..], "+");

        for (self.results.items) |_| {
            idx += self.appendChar(line[idx..], '-', col_width);
            idx += self.appendStr(line[idx..], "+");
        }

        std.log.info("{}", .{line[0..idx]});
    }

    fn printHeader(self: *ResultsReporter, metric_width: usize, col_width: usize) void {
        var line: [256]u8 = undefined;
        var idx: usize = 0;

        idx += self.appendStr(line[idx..], "| ");
        idx += self.appendStr(line[idx..], "Metric");
        idx += self.appendChar(line[idx..], ' ', metric_width - 2 - "Metric".len);
        idx += self.appendStr(line[idx..], " ");

        for (self.results.items) |named| {
            const padding = col_width - named.name.len;
            const left_pad = padding / 2;
            const right_pad = padding - left_pad;
            idx += self.appendStr(line[idx..], "|");
            idx += self.appendChar(line[idx..], ' ', left_pad);
            idx += self.appendStr(line[idx..], named.name);
            idx += self.appendChar(line[idx..], ' ', right_pad);
        }

        idx += self.appendStr(line[idx..], "|");
        std.log.info("{}", .{line[0..idx]});
    }

    fn printCountRow(self: *ResultsReporter, label: []const u8, field: []const u8, metric_width: usize, col_width: usize) void {
        var line: [256]u8 = undefined;
        var idx: usize = 0;

        idx += self.appendStr(line[idx..], "| ");
        idx += self.appendStr(line[idx..], label);
        idx += self.appendChar(line[idx..], ' ', metric_width - 2 - label.len);
        idx += self.appendStr(line[idx..], " ");

        for (self.results.items) |named| {
            const val: usize = if (std.mem.eql(u8, field, "allocation_count"))
                named.result.allocation_count
            else if (std.mem.eql(u8, field, "failure_count"))
                named.result.failure_count
            else
                0;
            idx += self.appendStr(line[idx..], "|");
            idx += self.appendNumRight(line[idx..], val, col_width - 1);
        }

        idx += self.appendStr(line[idx..], "|");
        std.log.info("{}", .{line[0..idx]});
    }

    fn printTimeRow(self: *ResultsReporter, label: []const u8, field: []const u8, metric_width: usize, col_width: usize) void {
        var line: [256]u8 = undefined;
        var idx: usize = 0;

        idx += self.appendStr(line[idx..], "| ");
        idx += self.appendStr(line[idx..], label);
        idx += self.appendChar(line[idx..], ' ', metric_width - 2 - label.len);
        idx += self.appendStr(line[idx..], " ");

        for (self.results.items) |named| {
            const time: u64 = if (std.mem.eql(u8, field, "alloc"))
                named.result.total_alloc_time_us
            else
                named.result.total_free_time_us;
            idx += self.appendStr(line[idx..], "|");
            idx += self.appendNumRight(line[idx..], time, col_width - 1);
        }

        idx += self.appendStr(line[idx..], "|");
        std.log.info("{}", .{line[0..idx]});
    }

    fn printBytesRow(self: *ResultsReporter, label: []const u8, field: []const u8, metric_width: usize, col_width: usize) void {
        var line: [256]u8 = undefined;
        var idx: usize = 0;

        idx += self.appendStr(line[idx..], "| ");
        idx += self.appendStr(line[idx..], label);
        idx += self.appendChar(line[idx..], ' ', metric_width - 2 - label.len);
        idx += self.appendStr(line[idx..], " ");

        for (self.results.items) |named| {
            const bytes: usize = if (std.mem.eql(u8, field, "capacity"))
                named.result.final_allocator_stats.total_capacity
            else if (std.mem.eql(u8, field, "peak"))
                named.result.final_allocator_stats.peak_usage
            else
                named.result.final_allocator_stats.current_usage;
            const kb = bytes / 1024;
            idx += self.appendStr(line[idx..], "|");
            idx += self.appendNumRight(line[idx..], kb, col_width - 1);
        }

        idx += self.appendStr(line[idx..], "|");
        std.log.info("{}", .{line[0..idx]});
    }

    fn printStatsCountRow(self: *ResultsReporter, label: []const u8, field: []const u8, metric_width: usize, col_width: usize) void {
        var line: [256]u8 = undefined;
        var idx: usize = 0;

        idx += self.appendStr(line[idx..], "| ");
        idx += self.appendStr(line[idx..], label);
        idx += self.appendChar(line[idx..], ' ', metric_width - 2 - label.len);
        idx += self.appendStr(line[idx..], " ");

        for (self.results.items) |named| {
            const count: usize = if (std.mem.eql(u8, field, "alloc_count"))
                named.result.final_allocator_stats.alloc_count
            else if (std.mem.eql(u8, field, "free_count"))
                named.result.final_allocator_stats.free_count
            else
                named.result.final_allocator_stats.alloc_failures;
            idx += self.appendStr(line[idx..], "|");
            idx += self.appendNumRight(line[idx..], count, col_width - 1);
        }

        idx += self.appendStr(line[idx..], "|");
        std.log.info("{}", .{line[0..idx]});
    }

    fn appendStr(self: *ResultsReporter, buf: []u8, s: []const u8) usize {
        _ = self;
        @memcpy(buf[0..s.len], s);
        return s.len;
    }

    fn appendChar(self: *ResultsReporter, buf: []u8, ch: u8, count: usize) usize {
        _ = self;
        for (0..count) |i| {
            buf[i] = ch;
        }
        return count;
    }

    fn appendNumRight(self: *ResultsReporter, buf: []u8, n: u64, width: usize) usize {
        _ = self;
        var num_buf: [20]u8 = undefined;
        var num_idx: usize = 0;

        if (n == 0) {
            num_buf[0] = '0';
            num_idx = 1;
        } else {
            var temp = n;
            while (temp > 0) {
                num_buf[num_idx] = @as(u8, @intCast(temp % 10)) + '0';
                temp /= 10;
                num_idx += 1;
            }
        }

        const padding = if (width > num_idx) width - num_idx else 0;
        for (0..padding) |i| {
            buf[i] = ' ';
        }

        var i: usize = padding;
        while (num_idx > 0) {
            num_idx -= 1;
            buf[i] = num_buf[num_idx];
            i += 1;
        }

        return i;
    }
};
