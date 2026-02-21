const c = @import("platform").c;
pub const TimeUnit = enum {
    nanoseconds,
    microseconds,
    milliseconds,
};

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

    pub fn getTimeElapsed(self: *const Timer, unit: TimeUnit) !u64 {
        const ticks = try getTicksElapsed(self);
        const clock_freq = @as(u64, c.PPC_TIMER_CLOCK);
        if (clock_freq == 0) {
            return error.InvalidClockFrequency;
        }

        return switch (unit) {
            .nanoseconds => (ticks * 1_000_000_000) / clock_freq,
            .microseconds => (ticks * 1_000_000) / clock_freq,
            .milliseconds => (ticks * 1_000) / clock_freq,
        };
    }

    pub fn getTicksElapsed(self: *const Timer) !u64 {
        if (self.end_time) |end_time| {
            return (end_time - self.start_time);
        } else {
            return error.StillTicking;
        }
    }
};

test "getNanosBeforeStop" {
    var timer = Timer.start();
    if (timer.getTimeElapsed(.nanoseconds) != error.StillTicking) {
        return error.TimerErrorHandleFail;
    }
}
