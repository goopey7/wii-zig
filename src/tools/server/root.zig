const std = @import("std");

pub fn runCrashReceiver() !void {
    const port = 9000;
    var addr = try std.net.Address.parseIp4("0.0.0.0", port);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    std.debug.print("Crash receiver listening on TCP port {}\n", .{port});

    while (true) {
        std.debug.print("Waiting for crash connection...\n", .{});
        const conn = server.accept() catch |err| switch (err) {
            error.ConnectionAborted => break,
            else => return err,
        };
        defer conn.stream.close();

        std.debug.print("Client connected!\n", .{});

        var buf: [1024]u8 = undefined;
        var total_read: usize = 0;

        while (total_read < 8) {
            const bytes_read = try conn.stream.read(buf[total_read..]);
            std.debug.print("Read {} bytes\n", .{bytes_read});
            if (bytes_read == 0) break;
            total_read += bytes_read;
        }

        std.debug.print("Total read: {}\n", .{total_read});

        if (total_read > 0) {
            const timestamp = std.time.timestamp();
            const filename = try std.fmt.allocPrint(std.heap.page_allocator, "crash_{d}.bin", .{timestamp});

            try std.fs.cwd().writeFile(.{ .sub_path = filename, .data = buf[0..total_read] });
            std.debug.print("Crash dump saved to {s}\n", .{filename});
        }
    }
}

pub fn runCSVHttpServer() !void {
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
        defer conn.stream.close();

        const handle = conn.stream.handle;

        var header_buf: [2048]u8 = undefined;
        var header_len: usize = 0;

        while (true) {
            const n_isize = try std.posix.recv(handle, header_buf[header_len..][0..1], 0);
            if (n_isize <= 0) {
                std.debug.print("Error reading headers or connection closed\n", .{});
                break;
            }
            header_len += @intCast(n_isize);

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
                _ = parts.next();
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
            const n_isize = try std.posix.recv(handle, read_buf[0..to_read], 0);
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
            const n_isize = try std.posix.send(handle, response[sent..], 0);
            if (n_isize <= 0) break;
            sent += @intCast(n_isize);
        }
    }
}
