const http = @import("http.zig");
const c = @import("platform.zig").c;
const dolphin = @import("dolphin.zig");
const std = @import("std");

pub const CRASH_DUMP_HOST = "192.168.0.115";
pub const CRASH_DUMP_PORT: u16 = 9000;
pub const CRASH_DUMP_HOST_DOLPHIN = CRASH_DUMP_HOST;
pub const CRASH_DUMP_PORT_DOLPHIN: u16 = 9000;

const max_stack: u32 = 4 * 1024;
const magic_header: u32 = 0xDEADC0DE;

var crash_socket: c_int = -1;
var target_addr: c.sockaddr_in = undefined;

pub var stack_top: u32 = 0;

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

pub fn init() !void {
    const is_dolphin = dolphin.isDolphin();
    const host = if (is_dolphin) CRASH_DUMP_HOST_DOLPHIN else CRASH_DUMP_HOST;
    const port = if (is_dolphin) CRASH_DUMP_PORT_DOLPHIN else CRASH_DUMP_PORT;
    crash_socket = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
    if (crash_socket < 0) {
        return error.SocketFailed;
    }

    target_addr = std.mem.zeroes(c.sockaddr_in);
    target_addr.sin_family = c.AF_INET;
    target_addr.sin_port = port;

    const ip_addr = c.inet_addr(host);
    if (ip_addr == c.INADDR_NONE) {
        return error.InvalidIP;
    }
    target_addr.sin_addr.s_addr = ip_addr;

    const conn_result = c.connect(crash_socket, @ptrCast(&target_addr), @sizeOf(c.sockaddr_in));
    if (conn_result < 0) {
        _ = c.net_close(crash_socket);
        crash_socket = -1;
        return error.ConnectionFailed;
    }
}

pub fn handler(exid: c_uint, ctx_ptr: [*c]c.PPCContext) callconv(.c) void {
    const exid_enum: Exid = @enumFromInt(exid);
    const log = std.log.scoped(.CrashHandler);
    const S = struct {
        var in_handler: bool = false;
    };
    if (S.in_handler) {
        log.info("Crashed inside of crash handler. Hanging indefinitely", .{});
        while (true) {}
    }
    S.in_handler = true;

    log.info("Crash handler triggered, socket={}", .{crash_socket});

    const ctx = if (ctx_ptr) |ctx| ctx.* else {
        log.info("Crash handler: no context", .{});
        while (true) {}
    };

    log.info("Sending crash dump, pc=0x{x}, exid={}", .{ ctx.pc, @tagName(exid_enum) });
    const to_copy: u32 = @min(max_stack, stack_top - ctx.gpr[1]);
    log.info("sp=0x{x} stack_top=0x{x} to_copy={}", .{ ctx.gpr[1], stack_top, to_copy });

    const stack_ptr: [*]const u8 = @ptrFromInt(ctx.gpr[1]);

    if (crash_socket >= 0) {
        var buf: [@sizeOf(u32) + @sizeOf(CrashDump) + max_stack]u8 = std.mem.zeroes([@sizeOf(u32) + @sizeOf(CrashDump) + max_stack]u8);
        @memcpy(buf[0..@sizeOf(u32)], std.mem.asBytes(&magic_header));

        var buf_offset: u32 = @sizeOf(u32);
        const exid_val: u32 = @intFromEnum(exid_enum);
        @memcpy(buf[buf_offset .. buf_offset + @sizeOf(u32)], std.mem.asBytes(&exid_val));
        buf_offset += @sizeOf(u32);

        @memcpy(buf[buf_offset .. buf_offset + @sizeOf(u32)], std.mem.asBytes(&ctx.pc));
        buf_offset += @sizeOf(u32);

        @memcpy(buf[buf_offset .. buf_offset + @sizeOf(u32)], std.mem.asBytes(&ctx.lr));
        buf_offset += @sizeOf(u32);

        @memcpy(buf[buf_offset .. buf_offset + @sizeOf(u32)], std.mem.asBytes(&ctx.ctr));
        buf_offset += @sizeOf(u32);

        @memcpy(buf[buf_offset .. buf_offset + @sizeOf(u32)], std.mem.asBytes(&ctx.cr));
        buf_offset += @sizeOf(u32);

        @memcpy(buf[buf_offset .. buf_offset + @sizeOf(u32)], std.mem.asBytes(&ctx.xer));
        buf_offset += @sizeOf(u32);

        @memcpy(buf[buf_offset .. buf_offset + @sizeOf(u32)], std.mem.asBytes(&ctx.msr));
        buf_offset += @sizeOf(u32);

        @memcpy(buf[buf_offset .. buf_offset + @sizeOf([32]u32)], std.mem.asBytes(&ctx.gpr));
        buf_offset += @sizeOf([32]u32);

        @memcpy(buf[buf_offset .. buf_offset + @sizeOf([32]u64)], std.mem.asBytes(&ctx.fpr));
        buf_offset += @sizeOf([32]u64);

        @memcpy(buf[buf_offset .. buf_offset + @sizeOf(u64)], std.mem.asBytes(&ctx.fpscr));
        buf_offset += @sizeOf(u64);

        @memcpy(buf[buf_offset .. buf_offset + @sizeOf([8]u32)], std.mem.asBytes(&ctx.gqr));
        buf_offset += @sizeOf([8]u32);

        @memcpy(buf[buf_offset .. buf_offset + @sizeOf([32]u64)], std.mem.asBytes(&ctx.ps));
        buf_offset += @sizeOf([32]u64);

        @memcpy(buf[buf_offset .. buf_offset + @sizeOf(u32)], std.mem.asBytes(&to_copy));
        buf_offset += @sizeOf(u32);

        @memcpy(buf[buf_offset .. buf_offset + to_copy], stack_ptr[0..to_copy]);

        _ = c.send(crash_socket, &buf, @sizeOf(u32) + @sizeOf(CrashDump) + to_copy, 0);
        {
            var i: u32 = 0;
            while (i < 100000) : (i += 1) {}
        }
        _ = c.net_close(crash_socket);
    } else {
        log.info("Invalid socket, not sending", .{});
    }

    c.SYS_ResetSystem(c.SYS_RETURNTOMENU, 0, 0);
}
