const c = @cImport({
    @cInclude("ogc/system.h");
});

export fn main() c_int {
    c.SYS_Report("Hello Wii from Zig!\n");
    return 0;
}
