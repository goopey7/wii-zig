const std = @import("std");
const builtin = @import("builtin");

const log = @import("platform").log;

pub const std_options = std.Options{
    .logFn = log,
};

export fn main() c_int {
    for (builtin.test_functions) |t| {
        t.func() catch {};
    }
    return 0;
}
