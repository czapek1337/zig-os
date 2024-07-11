const std = @import("std");

pub const Spinlock = struct {
    value: std.atomic.Value(bool) = .{ .raw = false },

    pub inline fn tryLock(self: *@This()) bool {
        return self.value.cmpxchgStrong(false, true, .acquire, .monotonic) == null;
    }

    pub inline fn lock(self: *@This()) void {
        while (!self.tryLock()) {
            std.atomic.spinLoopHint();
        }
    }

    pub inline fn unlock(self: *@This()) void {
        self.value.store(false, .release);
    }
};
