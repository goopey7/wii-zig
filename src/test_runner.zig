const app = @import("common/app.zig");
const c = app.c;

export fn main() c_int {
    c.SYS_Report("Hello!\n");
    return 0;
}
