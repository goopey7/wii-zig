const std = @import("std");
const c = @import("main.zig").c;

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    if (scope == std.log.default_log_scope) {
        _ = std.c.printf("%s: ", @tagName(level).ptr);
    } else {
        _ = std.c.printf("%s(%s): ", @tagName(level).ptr, @tagName(scope).ptr);
    }

    const ArgsType = @TypeOf(args);
    const args_type_info = @typeInfo(ArgsType);

    if (args_type_info != .@"struct") {
        @compileError("args must be a tuple");
    }

    comptime var arg_index = 0;
    comptime var i = 0;

    inline while (i < format.len) : (i += 1) {
        if (format[i] == '{' and i + 1 < format.len and format[i + 1] == '}') {
            const fields = args_type_info.@"struct".fields;
            if (arg_index < fields.len) {
                const value = @field(args, fields[arg_index].name);
                printValue(value);
                arg_index += 1;
            }
            i += 1;
        } else {
            _ = c.putchar(format[i]);
        }
    }

    _ = c.putchar('\n');
}

fn printValue(value: anytype) void {
    const T = @TypeOf(value);

    switch (@typeInfo(T)) {
        .int => {
            if (@typeInfo(T).int.signedness == .signed) {
                _ = std.c.printf("%lld", @as(c_longlong, value));
            } else {
                _ = std.c.printf("%llu", @as(c_ulonglong, value));
            }
        },
        .float => _ = std.c.printf("%f", @as(f64, value)),
        .bool => _ = std.c.printf("%s", if (value) "true".ptr else "false".ptr),
        .pointer => |ptr_info| {
            if (ptr_info.size == .slice and ptr_info.child == u8) {
                _ = std.c.printf("%.*s", @as(c_int, @intCast(value.len)), value.ptr);
            } else if (ptr_info.size == .One and ptr_info.is_const and ptr_info.child == [ptr_info.sentinel orelse 0:0]u8) {
                _ = std.c.printf("%s", value);
            } else {
                _ = std.c.printf("%p", value);
            }
        },
        .error_set => {
            _ = std.c.printf("%s", @errorName(value).ptr);
        },
        else => @compileError("Unable to print value"),
    }
}
