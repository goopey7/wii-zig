const c = @import("platform").c;

pub const Timer = struct {
    start_time: u64,
    end_time: ?u64,

    pub fn start() Timer {
        const ticks = c.SYS_Time();
        return .{
            .start_time = ticks,
            .end_time = null,
        };
    }

    pub fn stop(self: *Timer) void {
        const ticks = c.SYS_Time();
        self.end_time = ticks;
    }

    pub fn reset(self: *Timer) void {
        const ticks = c.SYS_Time();
        self.start_time = ticks;
        self.end_time = null;
    }

    pub fn getNanosecondsElapsed(self: *const Timer) !u64 {
        if (self.end_time) |end_time| {
            const nano: u64 = 1000000000;
            return (end_time - self.start_time) * (nano / @as(u64, c.PPC_TIMER_CLOCK));
        } else {
            return error.StillTicking;
        }
    }
};

test {
    var timer = Timer.start();
    _ = timer.getNanosecondsElapsed() catch {
        return;
    };
    return error.TimerErrorFail;
}
