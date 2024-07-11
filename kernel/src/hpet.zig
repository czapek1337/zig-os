const logger = std.log.scoped(.hpet);

const std = @import("std");

const acpi = @import("acpi.zig");
const pmm = @import("pmm.zig");

var hpet_address: u64 = undefined;
var counter_period: u64 = undefined;

const Register = enum(usize) {
    capabilities = 0x0,
    configuration = 0x10,
    main_counter = 0xf0,
};

inline fn getRegister(reg: Register) *volatile u64 {
    return pmm.virtualForPhysical(*volatile u64, hpet_address + @intFromEnum(reg));
}

pub fn initialize() void {
    var hpet_table: acpi.uacpi_table = undefined;

    std.debug.assert(acpi.uacpi_table_find_by_signature(
        acpi.ACPI_HPET_SIGNATURE,
        &hpet_table,
    ) == acpi.UACPI_STATUS_OK);

    const table: *acpi.acpi_hpet = @ptrCast(hpet_table.unnamed_0.hdr);

    std.debug.assert(table.address.address_space_id == acpi.UACPI_ADDRESS_SPACE_SYSTEM_MEMORY);

    hpet_address = table.address.address;
    counter_period = getRegister(.capabilities).* >> 32;

    logger.info("hpet base address is 0x{x}", .{hpet_address});
    logger.info("hpet counter period is {d} fs", .{counter_period});

    getRegister(.configuration).* &= ~@as(u64, 1 << 0);
    getRegister(.main_counter).* = 0;
    getRegister(.configuration).* |= @as(u64, 1 << 0);
}

pub inline fn readCounter() u64 {
    return getRegister(.main_counter).*;
}

pub inline fn currentNanos() u64 {
    return readCounter() * (counter_period / 1_000_000);
}

pub inline fn pollSleep(nanos: u64) void {
    const start = readCounter();
    const end = start + (nanos * 1_000_000) / counter_period;

    while (readCounter() < end) {
        std.atomic.spinLoopHint();
    }
}
