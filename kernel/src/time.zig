const logger = std.log.scoped(.time);

const root = @import("root");
const std = @import("std");

const apic = @import("apic.zig");
const arch = @import("arch.zig");
const hpet = @import("hpet.zig");
const interrupts = @import("interrupts.zig");

const TimerState = enum {
    disarmed,
    armed,
    fired,
};

pub const Timer = struct {
    deadline: u64,
    state: TimerState,

    pub inline fn arm(self: *Timer, deadline: u64) !void {
        std.debug.assert(self.state != .armed);

        self.deadline = deadline;
        self.state = .armed;

        try timers.add(self);
        processTimers();
    }
};

fn compareTimerDeadline(_: void, a: *Timer, b: *Timer) std.math.Order {
    return std.math.order(a.deadline, b.deadline);
}

const TimerPriorityQueue = std.PriorityQueue(*Timer, void, compareTimerDeadline);

var timers: TimerPriorityQueue = undefined;
var timer_vector: u8 = undefined;
var armed_deadline: u64 = 0;

fn timerHandler(_: *interrupts.InterruptFrame) callconv(.C) void {
    processTimers();
    apic.acknowledgeInterrupt();
}

pub fn initialize() void {
    timers = TimerPriorityQueue.init(root.allocator, {});
    timer_vector = interrupts.allocateVector();

    interrupts.registerHandler(timer_vector, timerHandler);
}

pub inline fn currentNanos() u64 {
    if (apic.isUsingTscDeadline()) {
        return arch.rdtsc() * std.time.ns_per_ms / apic.getTscTicksPerMs();
    } else {
        return hpet.currentNanos();
    }
}

pub fn createTimer() !*Timer {
    const timer = try root.allocator.create(Timer);

    timer.* = .{
        .deadline = 0,
        .state = .disarmed,
    };

    return timer;
}

pub fn processTimers() void {
    const current = currentNanos();

    while (timers.peek()) |it| {
        if (it.deadline > current) {
            break;
        }

        const timer = timers.remove();
        timer.state = .fired;

        // TODO: Do something with the timer
        // what the heck do i actually do??? lol i have no idea
        // logger.debug("timer with deadline {d} expired ({d}ns past deadline)", .{ timer.deadline, current - timer.deadline });
    }

    const next_timer = timers.peek() orelse return;

    if (armed_deadline != next_timer.deadline) {
        armed_deadline = next_timer.deadline;

        apic.armTimer(timer_vector, next_timer.deadline);
    }
}
