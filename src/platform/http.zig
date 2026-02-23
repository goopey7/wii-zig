const c = @import("root.zig").c;
const std = @import("std");

pub const Status = enum(u16) {
    ok = 200,
};
pub const Response = struct {
    status: Status,
    body: ?[]const u8,
};

pub fn post(url: []const u8, port: u16, data: []const u8) !Response {
    var splits = std.mem.splitAny(u8, url, "/");
    const hostname = splits.first();
    var hostname_buf: [256]u8 = undefined;
    @memcpy(hostname_buf[0..hostname.len], hostname);
    hostname_buf[hostname.len] = 0;

    var addr: c.sockaddr_in = std.mem.zeroes(c.sockaddr_in);
    addr.sin_family = c.AF_INET;
    addr.sin_port = port;

    const ip_numeric = c.inet_addr(&hostname_buf);
    if (ip_numeric != c.INADDR_NONE) {
        addr.sin_addr.s_addr = ip_numeric;
    } else {
        const host = c.net_gethostbyname(&hostname_buf);
        const addr_ptr: *const u32 = @ptrCast(@alignCast(host.*.h_addr_list[0]));
        addr.sin_addr.s_addr = addr_ptr.*;
    }

    const sock = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
    if (sock < 0) return error.SocketFailed;
    defer _ = c.net_close(sock);

    if (c.connect(sock, @ptrCast(&addr), @sizeOf(c.sockaddr_in)) < 0) {
        return error.ConnectFailed;
    }

    var route_buf: [256]u8 = undefined;
    const request_fmt = "POST /{s} HTTP/1.1\r\n" ++
        "Host: {s}\r\n" ++
        "Content-Type: text/csv\r\n" ++
        "Content-Length: {}\r\n" ++
        "\r\n" ++
        "{s}";

    const request = try std.fmt.bufPrint(&route_buf, request_fmt, .{ splits.rest(), hostname, data.len, data });

    var sent: usize = 0;
    while (sent < request.len) {
        const n = c.send(sock, request.ptr + sent, @intCast(request.len - sent), 0);
        if (n < 0) return error.SendFailed;
        sent += @intCast(n);
    }

    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    while (true) {
        const n = c.recv(sock, &buf, buf.len, 0);
        if (n < 0) return error.RecvFailed;
        if (n == 0) return error.ConnectionClosed;
        pos += @intCast(n);
        if (std.mem.indexOf(u8, buf[0..pos], "\r\n\r\n")) |_| {
            if (pos >= 4) {
                break;
            }
        }

        if (pos >= buf.len) return error.ResponseTooBig;
    }

    const response_data = buf[0..pos];

    const header_end = std.mem.indexOf(u8, response_data, "\r\n\r\n") orelse return error.InvalidHttp;
    const header_part = response_data[0..header_end];
    const body_part = response_data[header_end + 4 ..];

    var lines = std.mem.splitAny(u8, header_part, "\r\n");
    const status_line = lines.first();
    var parts = std.mem.splitAny(u8, status_line, " ");
    _ = parts.next();
    const status_code_str = parts.next().?;
    const status_code = try std.fmt.parseInt(u16, status_code_str, 10);

    const response: Response = .{ .body = body_part, .status = @enumFromInt(status_code) };
    return response;
}
