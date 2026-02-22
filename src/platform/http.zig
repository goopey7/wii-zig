const c = @import("root.zig").c;
const std = @import("std");

pub const Response = struct {};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub fn post(url: []const u8, headers: []const Header, data: []const u8) !Response {
    _ = headers;
    _ = data;
    var splits = std.mem.splitAny(u8, url, "/");
    const hostname = splits.first();
    var hostname_buf: [256]u8 = undefined;
    @memcpy(hostname_buf[0..hostname.len], hostname);
    hostname_buf[hostname.len] = 0;
    std.log.info("hostname: {}", .{hostname});

    const host = c.net_gethostbyname(&hostname_buf);
    var addr: c.sockaddr_in = std.mem.zeroes(c.sockaddr_in);
    addr.sin_family = c.AF_INET;
    addr.sin_port = 8080;

    if (host == null) {
        return error.isNull;
    }

    const addr_ptr: *const u32 = @ptrCast(@alignCast(host.*.h_addr_list[0]));
    addr.sin_addr.s_addr = addr_ptr.*;

    const sock = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
    if (sock < 0) return error.SocketFailed;
    if (c.connect(sock, @ptrCast(&addr), @sizeOf(c.sockaddr_in)) < 0) {
        _ = c.net_close(sock);
        return error.ConnectFailed;
    }

    const request = "POST / HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Content-Type: text/csv\r\n" ++
        "Content-Length: 13\r\n" ++
        "\r\n" ++
        "Hello,World";

    var sent: usize = 0;
    while (sent < request.len) {
        const n = c.send(sock, request.ptr + sent, @intCast(request.len - sent), 0);
        if (n < 0) return error.SendFailed;
        sent += @intCast(n);
    }

    var buf: [4096]u8 = undefined;
    const n = c.recv(sock, &buf, buf.len, 0);
    if (n < 0) return error.RecvFailed;

    const response = buf[0..@intCast(n)];
    std.log.info("Response: {}", .{response});

    _ = c.net_close(sock);
    
    return error.NotImplemented;
}
