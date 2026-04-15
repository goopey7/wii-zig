const std = @import("std");

pub fn deep_chain() void {
    deep_a();
}

noinline fn deep_a() void {
    deep_b();
}

noinline fn deep_b() void {
    deep_c();
}

noinline fn deep_c() void {
    deep_d();
}

noinline fn deep_d() void {
    deep_e();
}

noinline fn deep_e() void {
    const ptr: *volatile u8 = @ptrFromInt(0xBADC0DE);
    _ = ptr.*;
}
