const std = @import("std");
const builtin = @import("builtin");

pub const DevkitPpcHost = struct {
    os: []const u8,
    arch: []const u8,
    pub fn suffix(self: DevkitPpcHost, allocator: std.mem.Allocator) []const u8 {
        return std.fmt.allocPrint(allocator, "{s}_{s}", .{ self.os, self.arch }) catch @panic("failed to derive suffix!");
    }
};

pub fn resolveDevkitPpcHost() DevkitPpcHost {
    const target = builtin.target;
    const os = switch (target.os.tag) {
        .linux => "linux",
        .macos => "osx",
        .windows => "windows",
        else => @panic("Unsupported host OS for devkitPPC"),
    };
    const arch = switch (target.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .x86 => "i686",
        else => @panic("Unsupported host CPU architecture for devkitPPC"),
    };
    return .{
        .os = os,
        .arch = arch,
    };
}

pub fn build(b: *std.Build) void {
    const host = resolveDevkitPpcHost();
    std.debug.print("{s}", .{host.suffix(b.allocator)});
}
