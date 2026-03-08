const c = @import("platform.zig").c;
const std = @import("std");

pub fn isDolphin() bool {
    const S = struct {
        var has_checked_for_dolphin: bool = false;
        var is_dolphin: bool = false;
    };
    if (S.has_checked_for_dolphin) {
        return S.is_dolphin;
    }
    S.has_checked_for_dolphin = true;

    const fd = c.IOS_Open("/dev/dolphin", c.IPC_OPEN_READ);
    if (fd >= 0) {
        S.is_dolphin = true;
        _ = c.IOS_Close(fd);
    } else {
        S.is_dolphin = false;
    }
    return S.is_dolphin;
}
