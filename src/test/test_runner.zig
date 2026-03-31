const std = @import("std");
const builtin = @import("builtin");

const log = @import("platform").log;

pub const std_options = std.Options{
    .logFn = log,
};

export fn main() c_int {
    var passed: c_int = 0;
    var failed: c_int = 0;

    for (builtin.test_functions) |t| {
        if (t.func()) {
            std.log.info("{} succeded", .{t.name});
            passed += 1;
        } else |e| {
            std.log.err("{} failed with: {}", .{ t.name, e });
            failed += 1;
        }
    }

    std.log.info("===== Test Summary =====", .{});
    std.log.info("Passed: {}", .{passed});
    std.log.info("Failed: {}", .{failed});
    std.log.info("Total:  {}", .{passed + failed});

    return 0;
}
