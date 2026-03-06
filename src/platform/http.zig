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
        if (host) |h| {
            if (h.*.h_addr_list[0]) |addr_ptr| {
                const addr_p: *const u32 = @ptrCast(@alignCast(addr_ptr));
                addr.sin_addr.s_addr = addr_p.*;
            } else {
                return error.DnsNoAddress;
            }
        } else {
            return error.DnsFailed;
        }
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

pub const StreamingPost = struct {
    sock: c_int,
    buffer: [4096]u8 = undefined,
    buf_pos: usize = 0,

    pub fn writeAll(self: *StreamingPost, data: []const u8) !void {
        const remaining = data;

        if (self.buf_pos + remaining.len > self.buffer.len) {
            try self.flush();
        }

        if (remaining.len >= self.buffer.len) {
            var sent: usize = 0;
            while (sent < remaining.len) {
                const n = c.send(self.sock, remaining.ptr + sent, @intCast(remaining.len - sent), 0);
                if (n < 0) return error.SendFailed;
                sent += @intCast(n);
            }
        } else {
            @memcpy(self.buffer[self.buf_pos .. self.buf_pos + remaining.len], remaining);
            self.buf_pos += remaining.len;
        }
    }

    pub fn writeByte(self: *StreamingPost, byte: u8) !void {
        if (self.buf_pos >= self.buffer.len) {
            try self.flush();
        }
        self.buffer[self.buf_pos] = byte;
        self.buf_pos += 1;
    }

    pub fn print(self: *StreamingPost, comptime fmt: []const u8, args: anytype) !void {
        var buf: [256]u8 = undefined;
        const written = std.fmt.bufPrint(&buf, fmt, args) catch return error.BufferTooSmall;
        try self.writeAll(written);
    }

    pub fn flush(self: *StreamingPost) !void {
        if (self.buf_pos == 0) return;

        var sent: usize = 0;
        while (sent < self.buf_pos) {
            const n = c.send(self.sock, self.buffer[0..self.buf_pos].ptr + sent, @intCast(self.buf_pos - sent), 0);
            if (n < 0) return error.SendFailed;
            sent += @intCast(n);
        }
        self.buf_pos = 0;
    }

    pub fn readResponse(self: *StreamingPost) !Response {
        var buf: [4096]u8 = undefined;
        var pos: usize = 0;

        while (true) {
            const n = c.recv(self.sock, &buf, buf.len, 0);
            if (n < 0) {
                return error.RecvFailed;
            }
            if (n == 0) {
                break;
            }
            pos += @intCast(n);

            if (std.mem.indexOf(u8, buf[0..pos], "\r\n\r\n")) |_| {
                if (pos >= 4) {
                    break;
                }
            }

            if (pos >= buf.len) {
                return error.ResponseTooBig;
            }
        }

        const header_end = std.mem.indexOf(u8, buf[0..pos], "\r\n\r\n") orelse return error.InvalidHttp;
        const body_part = buf[header_end + 4 .. pos];

        var lines = std.mem.splitAny(u8, buf[0..header_end], "\r\n");
        var parts = std.mem.splitAny(u8, lines.first(), " ");
        _ = parts.next();
        const status_code = try std.fmt.parseInt(u16, parts.next().?, 10);
        return .{ .body = body_part, .status = @enumFromInt(status_code) };
    }

    pub fn close(self: *StreamingPost) void {
        _ = c.net_close(self.sock);
    }
};

pub fn postStreaming(url: []const u8, port: u16, content_length: usize) !StreamingPost {
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
        if (host) |h| {
            if (h.*.h_addr_list[0]) |addr_ptr| {
                const addr_p: *const u32 = @ptrCast(@alignCast(addr_ptr));
                addr.sin_addr.s_addr = addr_p.*;
            } else {
                return error.DnsNoAddress;
            }
        } else {
            return error.DnsFailed;
        }
    }

    const sock = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
    if (sock < 0) return error.SocketFailed;

    if (c.connect(sock, @ptrCast(&addr), @sizeOf(c.sockaddr_in)) < 0) {
        return error.ConnectFailed;
    }

    var route_buf: [256]u8 = undefined;
    const header_fmt = "POST /{s} HTTP/1.1\r\n" ++
        "Host: {s}\r\n" ++
        "Content-Type: text/csv\r\n" ++
        "Content-Length: {d}\r\n" ++
        "\r\n";

    const header = try std.fmt.bufPrint(&route_buf, header_fmt, .{ splits.rest(), hostname, content_length });

    var sent: usize = 0;
    while (sent < header.len) {
        const n = c.send(sock, header.ptr + sent, @intCast(header.len - sent), 0);
        if (n < 0) return error.SendFailed;
        sent += @intCast(n);
    }

    return StreamingPost{ .sock = sock };
}
