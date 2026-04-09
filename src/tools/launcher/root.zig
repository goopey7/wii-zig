const std = @import("std");
const builtin = @import("builtin");
const server = @import("server");

pub fn main() !void {
    const host_os = builtin.os.tag;
    const dolphin_exe = switch (host_os) {
        .windows => "C:\\Program Files\\Dolphin\\Dolphin.exe",
        else => "dolphin-emu-nogui",
    };
    const dolphin_args = switch (host_os) {
        .windows => "/e zig-out/wii-zig.dol",
        else => "zig-out/wii-zig.dol",
    };

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var argv = try std.process.argsWithAllocator(allocator);
    defer argv.deinit();

    _ = argv.skip();

    if (argv.next()) |_| {
        const wiiload_exe = argv.next().?;
        var wiiload = std.process.Child.init(&[_][]const u8{
            wiiload_exe, "zig-out/wii-zig.dol",
        }, allocator);
        try wiiload.spawn();
        _ = try wiiload.wait();

        try runServerThread();
    } else {
        _ = try std.Thread.spawn(.{}, runServerThread, .{});

        var dolphin = std.process.Child.init(&[_][]const u8{
            dolphin_exe,
            "-p", "headless",
            dolphin_args,
        }, allocator);
        try dolphin.spawn();

        _ = try dolphin.wait();

        std.debug.print("Dolphin exited. Server stopping.\n", .{});
    }
}

fn runServerThread() !void {
    const csv_http_thread = try std.Thread.spawn(.{}, server.runCSVHttpServer, .{});
    const crash_thread = try std.Thread.spawn(.{}, server.runCrashReceiver, .{});

    csv_http_thread.join();
    crash_thread.join();
}
