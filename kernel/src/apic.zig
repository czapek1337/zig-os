const logger = std.log.scoped(.apic);

const std = @import("std");

const arch = @import("arch.zig");
const cpu = @import("cpu.zig");
const hpet = @import("hpet.zig");
const pmm = @import("pmm.zig");

var ticks_per_ms: u32 = 0;
var tsc_ticks_per_ms: u64 = 0;
var use_tsc_deadline: bool = false;

var has_x2apic: bool = false;
var has_invariant_tsc: bool = false;
var has_tsc_deadline: bool = false;

const Register = enum(u64) {
    lapic_id = 0x20,
    eoi = 0xb0,
    spurious_vector = 0xf0,
    icr0 = 0x300,
    icr1 = 0x310,
    lvt_timer = 0x320,
    timer_initial_count = 0x380,
    timer_current_count = 0x390,
    timer_divide = 0x3e0,
};

inline fn getRegister(reg: Register) *volatile u32 {
    const cpu_data = cpu.getCpuData();
    return pmm.virtualForPhysical(*volatile u32, cpu_data.apic_address + @intFromEnum(reg));
}

pub inline fn isUsingTscDeadline() bool {
    return use_tsc_deadline;
}

pub inline fn getTscTicksPerMs() u64 {
    return tsc_ticks_per_ms;
}

pub inline fn acknowledgeInterrupt() void {
    getRegister(.eoi).* = 0;
}

pub fn initialize() void {
    const apic_msr = arch.rdmsr(.ia32_apic_base);

    // Make sure APIC is not in x2APIC mode and enable it
    std.debug.assert((apic_msr & (1 << 10)) == 0);
    arch.wrmsr(.ia32_apic_base, apic_msr | (1 << 11));

    const cpuid_1 = arch.cpuid(0x1, 0);
    const cpuid_80000007 = arch.cpuid(0x80000007, 0);

    has_x2apic = (cpuid_1.ecx & (1 << 21)) != 0;
    has_invariant_tsc = (cpuid_80000007.edx & (1 << 8)) != 0;
    has_tsc_deadline = (cpuid_1.ecx & (1 << 24)) != 0;
    use_tsc_deadline = has_invariant_tsc and has_tsc_deadline;

    logger.debug("cpu supports x2apic: {any}", .{has_x2apic});
    logger.debug("cpu supports invariant tsc: {any}", .{has_invariant_tsc});
    logger.debug("cpu supports tsc deadline timer: {any}", .{has_tsc_deadline});

    getRegister(.spurious_vector).* = 0xff | (1 << 8); // enable lapic

    if (use_tsc_deadline) {
        arch.wrmsr(.ia32_tsc_deadline, 0);
        getRegister(.lvt_timer).* = (0b10 << 17) | 0x80; // tsc deadline mode
    } else {
        getRegister(.lvt_timer).* = (0b00 << 17) | 0x80; // one-shot mode
    }

    const calibrate_period = 50;

    if (!use_tsc_deadline) {
        getRegister(.timer_divide).* = 0;
        getRegister(.timer_initial_count).* = 0xffffffff;
        hpet.pollSleep(std.time.ns_per_ms * calibrate_period);
        const elapsed = 0xffffffff - getRegister(.timer_current_count).*;
        getRegister(.timer_initial_count).* = 0;
        ticks_per_ms = elapsed / calibrate_period;
        logger.info("apic timer calibrated to {d} ticks per ms", .{ticks_per_ms});
    }

    const tsc_start = arch.rdtsc();
    hpet.pollSleep(std.time.ns_per_ms * calibrate_period);
    const tsc_elapsed = arch.rdtsc() - tsc_start;
    tsc_ticks_per_ms = tsc_elapsed / calibrate_period;
    logger.info("tsc calibrated to {d} ticks per ms", .{tsc_ticks_per_ms});
}

var vec: u8 = 0;

pub fn armTimer(vector: u8, nanos: u64) void {
    if (use_tsc_deadline) {
        const deadline = nanos * tsc_ticks_per_ms / std.time.ns_per_ms;
        getRegister(.lvt_timer).* = @as(u32, 0b10 << 17) | vector;
        arch.wrmsr(.ia32_tsc_deadline, deadline);
    } else {
        const ticks = (nanos - hpet.currentNanos()) * ticks_per_ms / std.time.ns_per_ms;
        getRegister(.lvt_timer).* = @as(u32, 0b00 << 17) | vector;
        getRegister(.timer_initial_count).* = @intCast(ticks);
    }
}
