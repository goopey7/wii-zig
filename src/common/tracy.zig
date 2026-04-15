const std = @import("std");
const options = @import("tracy_options");

pub const enabled = options.tracy_enabled;

const c = if (enabled) @cImport({
    @cDefine("TRACY_ENABLE", "1");
    @cDefine("TRACY_DELAYED_INIT", "1");
    @cDefine("TRACY_MANUAL_LIFETIME", "1");
    @cDefine("TRACY_NO_CALLSTACK", "1");
    @cDefine("TRACY_CALLSTACK", "0");
    @cDefine("TRACY_TIMER_FALLBACK", "1");
    @cInclude("tracy/TracyC.h");
}) else struct {};

pub const ZoneCtx = if (enabled) c.TracyCZoneCtx else void;

pub inline fn startup() void {
    if (enabled) c.___tracy_startup_profiler();
}

pub inline fn shutdown() void {
    if (enabled) c.___tracy_shutdown_profiler();
}

pub inline fn frameMark() void {
    if (enabled) c.___tracy_emit_frame_mark(null);
}

pub fn frameMarkFlush() void {
    if (!enabled) return;
    c.___tracy_emit_frame_mark(null);
    const usleep = @extern(*const fn (c_uint) callconv(.c) c_int, .{ .name = "usleep" });
    _ = usleep(5_000);
}

pub inline fn allocHook(ptr: ?*const anyopaque, size: usize) void {
    if (enabled) c.___tracy_emit_memory_alloc(ptr, size, 0);
}

pub inline fn freeHook(ptr: ?*const anyopaque) void {
    if (enabled) c.___tracy_emit_memory_free(ptr, 0);
}

pub inline fn plot(comptime name: [*:0]const u8, value: f64) void {
    if (!enabled) return;
    c.___tracy_emit_plot(name, value);
}

pub inline fn isConnected() bool {
    if (!enabled) return false;
    return c.___tracy_connected() != 0;
}

pub fn waitForConnection(timeout_ms: u32) bool {
    if (!enabled) return false;
    const usleep = @extern(*const fn (c_uint) callconv(.c) c_int, .{ .name = "usleep" });
    const poll_ms: u32 = 100;
    var elapsed: u32 = 0;
    while (!isConnected()) {
        _ = usleep(poll_ms * 1000);
        elapsed += poll_ms;
        if (elapsed >= timeout_ms) return false;
    }
    return true;
}

pub inline fn zoneBegin(comptime name: [*:0]const u8, comptime src: std.builtin.SourceLocation) ZoneCtx {
    if (!enabled) return;
    const S = struct {
        const loc: c.struct____tracy_source_location_data = .{
            .name = name,
            .function = src.fn_name.ptr,
            .file = src.file.ptr,
            .line = src.line,
            .color = 0,
        };
    };
    return c.___tracy_emit_zone_begin(&S.loc, 1);
}

pub inline fn zoneEnd(ctx: ZoneCtx) void {
    if (!enabled) return;
    var local = ctx;
    const impl = @extern(*const fn (*const ZoneCtx) callconv(.c) void, .{ .name = "___tracy_emit_zone_end" });
    impl(&local);
}
