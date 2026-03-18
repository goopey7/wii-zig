const std = @import("std");

const magic_markers = @as(u32, 0xDEADC0DE);
const max_scan_size = 4096;
const max_stack_size = 64 * 1024;
const max_receive_size = 65536;

pub const Exid = enum(u32) {
    Reset = 1,
    Mchk = 2,
    Dsi = 3,
    ISI = 4,
    IRQ = 5,
    ALIGN = 6,
    UNDEF = 7,
    FPU = 8,
    DECR = 9,
    SYSCALL = 12,
    TRACE = 13,
    PM = 15,
    BKPT = 19,
};

pub const CrashDump = struct {
    exid: Exid,
    pc: u32, // program counter (address of where we crashed)
    lr: u32, // link register (where execution would go when the current function returns)
    ctr: u32, // count register (loop counters)
    cr: u32, // condition register (results of comparisons)
    xer: u32, // fixed point exception register. (integer overflow, carry bits)
    msr: u32, // machine state register at the time of exception.
    gpr: [32]u32, // general purpose registers r0-r31
    fpr: [32]u64, // floating point registers f0-f31
    fpscr: u64, // floating point equivalent of xer
    gqr: [8]u32, // graphics quantization registers
    ps: [32]u64, // paired singles (wii specific)
    stack_len: u32, // needed to signal TCP receiver how much data to read
};

pub fn runCrashReceiver() !void {
    const log = std.log.scoped(.CrashReceiver);
    const port = 9000;
    var addr = try std.net.Address.parseIp4("0.0.0.0", port);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    log.info("Crash receiver listening on TCP port {}", .{port});

    while (true) {
        log.debug("Waiting for crash connection...", .{});
        const conn = server.accept() catch |err| switch (err) {
            error.ConnectionAborted => break,
            else => return err,
        };
        defer conn.stream.close();

        log.debug("Client connected!", .{});

        var tmp_buf: [max_scan_size]u8 = undefined;
        var tmp_read: usize = 0;
        var magic_pos: usize = 0;
        var found_magic = false;

        while (!found_magic) {
            const n = try conn.stream.read(tmp_buf[tmp_read..]);
            if (n == 0) {
                log.warn("Connection closed while scanning for magic", .{});
                break;
            }
            tmp_read += n;

            while (magic_pos + 4 <= tmp_read) {
                const val = std.mem.readInt(u32, tmp_buf[magic_pos..][0..4], .big);
                if (val == magic_markers) {
                    found_magic = true;
                    if (magic_pos > 0) {
                        log.warn("Skipped {} bytes before magic", .{magic_pos});
                    }
                    break;
                }
                magic_pos += 1;
            }

            if (tmp_read > max_scan_size and !found_magic) {
                log.warn("No magic header found in first {} bytes", .{tmp_read});
                break;
            }
        }

        if (!found_magic) {
            log.warn("Failed to find magic header", .{});
            continue;
        }

        const header_size = @sizeOf(CrashDump);
        const header_start = magic_pos + 4;

        const needed_for_header = header_start + header_size;
        if (tmp_read < needed_for_header) {
            const more_needed = needed_for_header - tmp_read;
            const n = try conn.stream.read(tmp_buf[tmp_read..][0..more_needed]);
            tmp_read += n;
        }

        const stack_len_offset = header_start + header_size - 4;
        const stack_len = std.mem.readInt(u32, tmp_buf[stack_len_offset..][0..4], .big);
        const clamped_stack_len = @min(stack_len, max_stack_size);

        const total_expected = 4 + header_size + clamped_stack_len;
        var all_data = try std.heap.page_allocator.alloc(u8, tmp_read + max_receive_size);
        defer std.heap.page_allocator.free(all_data);

        const remaining_data_len = tmp_read - magic_pos;
        @memcpy(all_data[0..remaining_data_len], tmp_buf[magic_pos..][0..remaining_data_len]);

        var total_read = remaining_data_len;
        while (total_read < total_expected) {
            const n = conn.stream.read(all_data[total_read..]) catch break;
            if (n == 0) break;
            total_read += n;
        }

        const header_skip = magic_pos + 4;
        const header_data = all_data[header_skip..][0..header_size];
        const stack_start = header_skip + header_size;
        const actual_stack_len = @min(clamped_stack_len, total_read - stack_start);
        const stack_data = all_data[stack_start..][0..actual_stack_len];

        const timestamp = std.time.timestamp();
        const filename = try std.fmt.allocPrint(
            std.heap.page_allocator,
            "crash_{d}.bin",
            .{timestamp},
        );
        defer std.heap.page_allocator.free(filename);

        const file = try std.fs.cwd().createFile(filename, .{});
        defer file.close();
        try file.writeAll(header_data);
        try file.writeAll(stack_data);

        log.info("Crash dump saved to {s} ({} header + {} stack bytes)", .{
            filename,
            @sizeOf(CrashDump),
            stack_data.len,
        });
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
