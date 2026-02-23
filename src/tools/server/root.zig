const std = @import("std");

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

        defer conn.stream.close();

        var reader_buf: [1024]u8 = undefined;
        var writer_buf: [1024]u8 = undefined;

        var reader = conn.stream.reader(&reader_buf).file_reader;
        var writer = conn.stream.writer(&writer_buf).file_writer;

        var server_http = std.http.Server.init(&reader.interface, &writer.interface);

        var req = try server_http.receiveHead();

        if (req.head.method == .POST) {
            var buffer: [1024]u8 = undefined;
            var body_reader = server_http.reader.bodyReader(&buffer, .none, req.head.content_length);
            const body = try body_reader.readAlloc(allocator, req.head.content_length.?);

            const now = std.time.timestamp();
            const filename = try std.fmt.allocPrint(allocator, "{}.csv", .{now});
            const file = try std.fs.cwd().createFile(filename, .{ .truncate = true });
            defer file.close();
            try file.writeAll(body);
            std.debug.print("CSV saved to {s}\n", .{filename});

            try req.respond("CSV received successfully!", .{});
        } else {
            try req.respond("Only POST requests are accepted.", .{});
        }
    }
}
