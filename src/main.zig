const std = @import("std");

pub const std_options = .{
    .log_level = .debug,
};

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    _ = msg;
    _ = error_return_trace;
    _ = ret_addr;
    while (true) {}
}

export fn main() c_int {
    return 0;
}

test "a wii test" {
    const testies = 3;
    try std.testing.expectEqual(testies, 3);
}
