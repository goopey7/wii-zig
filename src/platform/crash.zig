const http = @import("http.zig");
const c = @import("platform.zig").c;
const dolphin = @import("dolphin.zig");
const std = @import("std");

pub const CRASH_DUMP_HOST = "192.168.0.107";
pub const CRASH_DUMP_PORT: u16 = 9000;
pub const CRASH_DUMP_HOST_DOLPHIN = "127.0.0.1";
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
    ZigPanic = 20,
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

pub fn sendPanic(panic_msg: []const u8, error_trace: ?*std.builtin.StackTrace) noreturn {
    const S = struct {
        var in_panic: bool = false;
        var buf: [@sizeOf(u32) + @sizeOf(CrashDump) + max_stack]u8 = undefined;
    };
    if (S.in_panic) {
        while (true) {}
    }
    S.in_panic = true;

    // don't use std.log here to avoid extra allocations which might not be possible in an OOM situation
    _ = std.c.printf("err(CrashHandler): PANIC: %.*s\n", @as(c_int, @intCast(panic_msg.len)), panic_msg.ptr);
    c.SYS_Report("err(CrashHandler): PANIC: %.*s\n", @as(c_int, @intCast(panic_msg.len)), panic_msg.ptr);

    // get stack ptr and link register
    const sp = asm volatile ("mr %[out], 1"
        : [out] "=r" (-> u32),
    );
    const lr = asm volatile ("mflr %[out]"
        : [out] "=r" (-> u32),
    );

    var pc: u32 = lr;
    if (error_trace) |trace| {
        const n = @min(trace.index, trace.instruction_addresses.len);
        if (n > 0) {
            pc = @intCast(trace.instruction_addresses[0]);
        }
    }

    if (crash_socket >= 0) {
        const to_copy: u32 = @min(max_stack, stack_top - sp);
        const stack_ptr: [*]const u8 = @ptrFromInt(sp);

        _ = std.c.printf("err(CrashHandler): Sending crash dump (socket=%d, stack_bytes=%u)\n", crash_socket, to_copy);
        c.SYS_Report("err(CrashHandler): Sending crash dump\n");

        @memset(&S.buf, 0);
        @memcpy(S.buf[0..@sizeOf(u32)], std.mem.asBytes(&magic_header));

        var buf_offset: u32 = @sizeOf(u32);
        const exid_val: u32 = @intFromEnum(Exid.ZigPanic);
        @memcpy(S.buf[buf_offset .. buf_offset + @sizeOf(u32)], std.mem.asBytes(&exid_val));
        buf_offset += @sizeOf(u32);

        @memcpy(S.buf[buf_offset .. buf_offset + @sizeOf(u32)], std.mem.asBytes(&pc));
        buf_offset += @sizeOf(u32);

        @memcpy(S.buf[buf_offset .. buf_offset + @sizeOf(u32)], std.mem.asBytes(&lr));
        buf_offset += @sizeOf(u32);

        // skip ctr, cr, xer, msr
        buf_offset += @sizeOf(u32) * 4;

        // gpr[0..32] also zeroed except gpr[1]
        var gpr = std.mem.zeroes([32]u32);
        gpr[1] = sp;
        @memcpy(S.buf[buf_offset .. buf_offset + @sizeOf([32]u32)], std.mem.asBytes(&gpr));
        buf_offset += @sizeOf([32]u32);

        // fpr, fpscr, gqr, ps also zeroed
        buf_offset += @sizeOf([32]u64); // fpr
        buf_offset += @sizeOf(u64); // fpscr
        buf_offset += @sizeOf([8]u32); // gqr
        buf_offset += @sizeOf([32]u64); // ps

        @memcpy(S.buf[buf_offset .. buf_offset + @sizeOf(u32)], std.mem.asBytes(&to_copy));
        buf_offset += @sizeOf(u32);

        @memcpy(S.buf[buf_offset .. buf_offset + to_copy], stack_ptr[0..to_copy]);

        _ = c.send(crash_socket, &S.buf, @sizeOf(u32) + @sizeOf(CrashDump) + to_copy, 0);
        _ = std.c.printf("err(CrashHandler): Crash dump sent\n");
        c.SYS_Report("err(CrashHandler): Crash dump sent\n");
        {
            var i: u32 = 0;
            while (i < 100000) : (i += 1) {}
        }
        _ = c.net_close(crash_socket);
    } else {
        _ = std.c.printf("err(CrashHandler): No crash socket\n");
        c.SYS_Report("err(CrashHandler): No crash socket\n");
    }

    c.SYS_ResetSystem(c.SYS_RETURNTOMENU, 0, 0);
    unreachable;
}

// Static storage for the crash buffer so the handler doesn't need stack space
const handler_state = struct {
    var buf: [@sizeOf(u32) + @sizeOf(CrashDump) + max_stack]u8 = undefined;
    var send_len: usize = 0;
};

noinline fn sendCrashFromNormalContext() noreturn {
    if (handler_state.send_len > 0) {
        _ = c.send(crash_socket, &handler_state.buf, handler_state.send_len, 0);
        // wait to give the TCP stack time to flush before closing
        var i: u32 = 0;
        while (i < 1000000) : (i += 1) {}
        _ = c.net_close(crash_socket);
    }
    c.exit(0);
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
        @memset(&handler_state.buf, 0);
        @memcpy(handler_state.buf[0..@sizeOf(u32)], std.mem.asBytes(&magic_header));

        var buf_offset: u32 = @sizeOf(u32);
        const exid_val: u32 = @intFromEnum(exid_enum);
        @memcpy(handler_state.buf[buf_offset .. buf_offset + @sizeOf(u32)], std.mem.asBytes(&exid_val));
        buf_offset += @sizeOf(u32);

        @memcpy(handler_state.buf[buf_offset .. buf_offset + @sizeOf(u32)], std.mem.asBytes(&ctx.pc));
        buf_offset += @sizeOf(u32);

        @memcpy(handler_state.buf[buf_offset .. buf_offset + @sizeOf(u32)], std.mem.asBytes(&ctx.lr));
        buf_offset += @sizeOf(u32);

        @memcpy(handler_state.buf[buf_offset .. buf_offset + @sizeOf(u32)], std.mem.asBytes(&ctx.ctr));
        buf_offset += @sizeOf(u32);

        @memcpy(handler_state.buf[buf_offset .. buf_offset + @sizeOf(u32)], std.mem.asBytes(&ctx.cr));
        buf_offset += @sizeOf(u32);

        @memcpy(handler_state.buf[buf_offset .. buf_offset + @sizeOf(u32)], std.mem.asBytes(&ctx.xer));
        buf_offset += @sizeOf(u32);

        @memcpy(handler_state.buf[buf_offset .. buf_offset + @sizeOf(u32)], std.mem.asBytes(&ctx.msr));
        buf_offset += @sizeOf(u32);

        @memcpy(handler_state.buf[buf_offset .. buf_offset + @sizeOf([32]u32)], std.mem.asBytes(&ctx.gpr));
        buf_offset += @sizeOf([32]u32);

        @memcpy(handler_state.buf[buf_offset .. buf_offset + @sizeOf([32]u64)], std.mem.asBytes(&ctx.fpr));
        buf_offset += @sizeOf([32]u64);

        @memcpy(handler_state.buf[buf_offset .. buf_offset + @sizeOf(u64)], std.mem.asBytes(&ctx.fpscr));
        buf_offset += @sizeOf(u64);

        @memcpy(handler_state.buf[buf_offset .. buf_offset + @sizeOf([8]u32)], std.mem.asBytes(&ctx.gqr));
        buf_offset += @sizeOf([8]u32);

        @memcpy(handler_state.buf[buf_offset .. buf_offset + @sizeOf([32]u64)], std.mem.asBytes(&ctx.ps));
        buf_offset += @sizeOf([32]u64);

        @memcpy(handler_state.buf[buf_offset .. buf_offset + @sizeOf(u32)], std.mem.asBytes(&to_copy));
        buf_offset += @sizeOf(u32);

        @memcpy(handler_state.buf[buf_offset .. buf_offset + to_copy], stack_ptr[0..to_copy]);

        handler_state.send_len = @sizeOf(u32) + @sizeOf(CrashDump) + to_copy;
    } else {
        log.info("Invalid socket, not sending", .{});
        handler_state.send_len = 0;
    }

    // use rfi (return from interrupt) to return to a normal context
    // and immediately jump to sendCrashFromNormalContext to send the crash data
    asm volatile ("mtsrr0 %[addr]\nmtsrr1 %[msr]\nrfi\n"
        :
        : [addr] "r" (@intFromPtr(&sendCrashFromNormalContext)),
          [msr] "r" (ctx.msr),
    );
    unreachable;
}
