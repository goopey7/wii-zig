const std = @import("std");
const runServer = @import("server").runServer;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var argv = try std.process.argsWithAllocator(allocator);
    defer argv.deinit();

    _ = argv.skip();

    if (argv.next()) |_| {
        var wiiload = std.process.Child.init(&[_][]const u8{
            "wiiload", "zig-out/wii-zig.dol",
        }, allocator);
        try wiiload.spawn();
        _ = try wiiload.wait();

        try runServerThread();
    } else {
        _ = try std.Thread.spawn(.{}, runServerThread, .{});

        var dolphin = std.process.Child.init(&[_][]const u8{
            "dolphin-emu-nogui",
            "zig-out/wii-zig.dol",
        }, allocator);
        try dolphin.spawn();

        _ = try dolphin.wait();

        std.debug.print("Dolphin exited. Server stopping.\n", .{});
    }
}

fn runServerThread() !void {
    try runServer();
}
