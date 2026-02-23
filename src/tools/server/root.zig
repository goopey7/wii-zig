const std = @import("std");
const c = @cImport({
    @cInclude("sys/socket.h");
});

pub fn runServer() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const address = try std.net.Address.parseIp4("0.0.0.0", 3000);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    while (true) {
        const conn = server.accept() catch |err| switch (err) {
            error.ConnectionAborted => break,
            else => return err,
        };

        const sock = @as(c_int, @intCast(conn.stream.handle));

        var header_buf: [2048]u8 = undefined;
        var header_len: usize = 0;

        while (true) {
            const n = c.recv(sock, &header_buf[header_len], 1, 0);
            if (n <= 0) {
                std.debug.print("Error reading headers or connection closed\n", .{});
                break;
            }
            header_len += @intCast(n);

            if (header_len >= 4) {
                if (std.mem.eql(u8, header_buf[header_len - 4 ..][0..4], "\r\n\r\n")) {
                    break;
                }
            }
            if (header_len >= header_buf.len) {
                std.debug.print("Headers too long\n", .{});
                break;
            }
        }

        const headers = header_buf[0..header_len];

        var content_length: usize = 0;
        var lines = std.mem.splitAny(u8, headers, "\r\n");
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "Content-Length:")) {
                var parts = std.mem.splitAny(u8, line, " ");
                _ = parts.next(); // skip "Content-Length:"
                if (parts.next()) |len_str| {
                    content_length = try std.fmt.parseInt(usize, len_str, 10);
                }
            }
        }

        var body_buf = try allocator.alloc(u8, content_length);
        defer allocator.free(body_buf);

        var body_read: usize = 0;
        var read_buf: [8192]u8 = undefined;
        while (body_read < content_length) {
            const to_read = @min(read_buf.len, content_length - body_read);
            const n_isize = c.recv(sock, &read_buf, to_read, 0);
            if (n_isize <= 0) {
                std.debug.print("Connection closed while reading body, got {} of {}\n", .{ body_read, content_length });
                break;
            }
            const n: usize = @intCast(n_isize);
            @memcpy(body_buf[body_read .. body_read + n], read_buf[0..n]);
            body_read += n;
        }

        const now = std.time.timestamp();
        const filename = try std.fmt.allocPrint(allocator, "{}.csv", .{now});
        const file = try std.fs.cwd().createFile(filename, .{ .truncate = true });
        defer file.close();
        try file.writeAll(body_buf[0..body_read]);

        const response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 25\r\n\r\nCSV received successfully!";
        var sent: usize = 0;
        while (sent < response.len) {
            const n = c.send(sock, response.ptr + sent, response.len - sent, 0);
            if (n <= 0) break;
            sent += @intCast(n);
        }

        conn.stream.close();
    }
}
