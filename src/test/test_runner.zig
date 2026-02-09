const std = @import("std");
const builtin = @import("builtin");

const log = @import("platform").log;

pub const std_options = std.Options{
    .logFn = log,
};

export fn main() c_int {
    for (builtin.test_functions) |t| {
        if (t.func()) {
            std.log.info("{} succeded", .{t.name});
        } else |e| {
            std.log.err("{} failed with: {}", .{ t.name, e });
        }
    }
    return 0;
}
