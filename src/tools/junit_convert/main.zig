const std = @import("std");

const TestResult = struct {
    name: []const u8,
    passed: bool,
    err_msg: ?[]const u8 = null,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var argv = try std.process.argsWithAllocator(allocator);
    defer argv.deinit();
    _ = argv.skip();

    const input_path = argv.next() orelse {
        try std.fs.File.stderr().writeAll("Usage: junit_convert <input.log> <output.xml>\n");
        return error.InvalidArgs;
    };

    const output_path = argv.next() orelse {
        try std.fs.File.stderr().writeAll("Usage: junit_convert <input.log> <output.xml>\n");
        return error.InvalidArgs;
    };

    const input_file = try std.fs.cwd().openFile(input_path, .{});
    defer input_file.close();

    const input = try input_file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(input);

    var tests = try std.ArrayList(TestResult).initCapacity(allocator, 100);

    var lines = std.mem.splitAny(u8, input, "\r\n");
    while (lines.next()) |line| {
        const result = try parseLine(line, allocator);
        if (result) |t| {
            try tests.append(allocator, t);
        }
    }

    const total_tests = tests.items.len;
    const failed_count = countFailed(tests.items);

    var xml_parts = try std.ArrayList([]const u8).initCapacity(allocator, 64);
    defer xml_parts.deinit(allocator);

    try xml_parts.append(allocator, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>");
    try xml_parts.append(allocator, try std.fmt.allocPrint(allocator, "<testsuites tests=\"{}\" failures=\"{}\" time=\"0.000\">", .{ total_tests, failed_count }));
    try xml_parts.append(allocator, try std.fmt.allocPrint(allocator, "  <testsuite name=\"wii-zig\" tests=\"{}\" failures=\"{}\" time=\"0.000\">", .{ total_tests, failed_count }));

    for (tests.items) |tst| {
        const classname = getClassname(tst.name);
        const name = getName(tst.name);

        if (tst.passed) {
            try xml_parts.append(allocator, try std.fmt.allocPrint(allocator, "    <testcase classname=\"{s}\" name=\"{s}\" time=\"0.000\"/>", .{ classname, name }));
        } else {
            const error_msg = tst.err_msg orelse "test failed";
            try xml_parts.append(allocator, try std.fmt.allocPrint(allocator, "    <testcase classname=\"{s}\" name=\"{s}\" time=\"0.000\">", .{ classname, name }));
            try xml_parts.append(allocator, try std.fmt.allocPrint(allocator, "      <failure>{s}</failure>", .{error_msg}));
            try xml_parts.append(allocator, "    </testcase>");
        }
    }

    try xml_parts.append(allocator, "  </testsuite>");
    try xml_parts.append(allocator, "</testsuites>");

    const output = try std.mem.concat(allocator, u8, xml_parts.items);
    defer allocator.free(output);

    const out_file = try std.fs.cwd().createFile(output_path, .{});
    defer out_file.close();
    try out_file.writeAll(output);

    if (failed_count > 0) {
        return error.TestsFailed;
    }
}

fn parseLine(line: []const u8, allocator: std.mem.Allocator) !?TestResult {
    const suffix_idx = std.mem.lastIndexOf(u8, line, " succeded") orelse std.mem.lastIndexOf(u8, line, " failed with: ");
    if (suffix_idx == null) return null;

    const after_timestamp = if (std.mem.indexOf(u8, line, ": info: ")) |idx|
        line[idx + 8 .. suffix_idx.?]
    else if (std.mem.indexOf(u8, line, ": err: ")) |idx|
        line[idx + 7 .. suffix_idx.?]
    else
        return null;

    const is_passed = std.mem.indexOf(u8, line, ": info: ") != null;
    const name = after_timestamp;

    var err_msg: ?[]const u8 = null;
    if (!is_passed) {
        if (std.mem.indexOf(u8, line, " failed with: ")) |err_idx| {
            const err_start = err_idx + 14;
            err_msg = try allocator.dupe(u8, line[err_start..]);
        }
    }

    return TestResult{ .name = try allocator.dupe(u8, name), .passed = is_passed, .err_msg = err_msg };
}

fn getClassname(name: []const u8) []const u8 {
    const first_dot = std.mem.indexOf(u8, name, ".") orelse return name;
    return name[0..first_dot];
}

fn getName(name: []const u8) []const u8 {
    const first_dot = std.mem.indexOf(u8, name, ".") orelse return name;
    return name[first_dot + 1 ..];
}

fn countFailed(tests: []TestResult) usize {
    var count: usize = 0;
    for (tests) |tst| {
        if (!tst.passed) count += 1;
    }
    return count;
}
