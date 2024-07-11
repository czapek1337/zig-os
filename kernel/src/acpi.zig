const C = @cImport({
    @cInclude("uacpi/acpi.h");
    @cInclude("uacpi/tables.h");
    @cInclude("uacpi/uacpi.h");
});

pub usingnamespace C;

const logger = std.log.scoped(.acpi);

const limine = @import("limine");
const root = @import("root");
const std = @import("std");

const arch = @import("arch.zig");
const pmm = @import("pmm.zig");
const sync = @import("sync.zig");

export var rsdp_request: limine.RsdpRequest = .{};

pub fn initialize() void {
    const rsdp_response = rsdp_request.response.?;
    const init_params: C.uacpi_init_params = .{
        .rsdp = @intFromPtr(rsdp_response.address) - pmm.virtualForPhysical(u64, 0),
        .log_level = C.UACPI_LOG_DEBUG,
        .flags = 0,
    };

    std.debug.assert(C.uacpi_initialize(&init_params) == C.UACPI_STATUS_OK);
}

export fn uacpi_kernel_raw_memory_read(
    address: C.uacpi_phys_addr,
    byte_width: C.uacpi_u8,
    out_value: *C.uacpi_u64,
) callconv(.C) C.uacpi_status {
    switch (byte_width) {
        1 => {
            const value = pmm.virtualForPhysical(*volatile u8, address);
            out_value.* = value.*;
        },
        2 => {
            const value = pmm.virtualForPhysical(*volatile u16, address);
            out_value.* = value.*;
        },
        4 => {
            const value = pmm.virtualForPhysical(*volatile u32, address);
            out_value.* = value.*;
        },
        8 => {
            const value = pmm.virtualForPhysical(*volatile u64, address);
            out_value.* = value.*;
        },
        else => return C.UACPI_STATUS_INVALID_ARGUMENT,
    }

    return C.UACPI_STATUS_OK;
}

export fn uacpi_kernel_raw_memory_write(
    address: C.uacpi_phys_addr,
    byte_width: C.uacpi_u8,
    in_value: C.uacpi_u64,
) callconv(.C) C.uacpi_status {
    switch (byte_width) {
        1 => {
            const ptr = pmm.virtualForPhysical(*volatile u8, address);
            ptr.* = @intCast(in_value);
        },
        2 => {
            const ptr = pmm.virtualForPhysical(*volatile u16, address);
            ptr.* = @intCast(in_value);
        },
        4 => {
            const ptr = pmm.virtualForPhysical(*volatile u32, address);
            ptr.* = @intCast(in_value);
        },
        8 => {
            const ptr = pmm.virtualForPhysical(*volatile u64, address);
            ptr.* = @intCast(in_value);
        },
        else => return C.UACPI_STATUS_INVALID_ARGUMENT,
    }

    return C.UACPI_STATUS_OK;
}

export fn uacpi_kernel_raw_io_read(
    address: C.uacpi_io_addr,
    byte_width: C.uacpi_u8,
    out_value: *C.uacpi_u64,
) callconv(.C) C.uacpi_status {
    const port: u16 = @intCast(address);

    switch (byte_width) {
        1 => out_value.* = arch.inb(port),
        2 => out_value.* = arch.inw(port),
        4 => out_value.* = arch.inl(port),
        else => return C.UACPI_STATUS_INVALID_ARGUMENT,
    }

    return C.UACPI_STATUS_OK;
}

export fn uacpi_kernel_raw_io_write(
    address: C.uacpi_io_addr,
    byte_width: C.uacpi_u8,
    in_value: C.uacpi_u64,
) callconv(.C) C.uacpi_status {
    const port: u16 = @intCast(address);

    switch (byte_width) {
        1 => arch.outb(port, @intCast(in_value)),
        2 => arch.outw(port, @intCast(in_value)),
        4 => arch.outl(port, @intCast(in_value)),
        else => return C.UACPI_STATUS_INVALID_ARGUMENT,
    }

    return C.UACPI_STATUS_OK;
}

export fn uacpi_kernel_pci_read(
    address: *C.uacpi_pci_address,
    offset: C.uacpi_size,
    byte_width: C.uacpi_u8,
    value: *C.uacpi_u64,
) callconv(.C) C.uacpi_status {
    _ = address;
    _ = offset;
    _ = byte_width;
    _ = value;
    return C.UACPI_STATUS_UNIMPLEMENTED;
}

export fn uacpi_kernel_pci_write(
    address: *C.uacpi_pci_address,
    offset: C.uacpi_size,
    byte_width: C.uacpi_u8,
    value: C.uacpi_u64,
) callconv(.C) C.uacpi_status {
    _ = address;
    _ = offset;
    _ = byte_width;
    _ = value;
    return C.UACPI_STATUS_UNIMPLEMENTED;
}

const MappedIo = struct {
    base: u16,
    length: usize,
};

export fn uacpi_kernel_io_map(
    base: C.uacpi_io_addr,
    len: C.uacpi_size,
    out_handle: *C.uacpi_handle,
) callconv(.C) C.uacpi_status {
    const handle = root.allocator.create(MappedIo) catch return C.UACPI_STATUS_OUT_OF_MEMORY;

    handle.* = .{ .base = @intCast(base), .length = len };
    out_handle.* = @ptrCast(handle);

    return C.UACPI_STATUS_OK;
}

export fn uacpi_kernel_io_unmap(handle: C.uacpi_handle) callconv(.C) void {
    root.allocator.destroy(@as(*MappedIo, @ptrCast(@alignCast(handle))));
}

export fn uacpi_kernel_io_read(
    handle: C.uacpi_handle,
    offset: C.uacpi_size,
    byte_width: C.uacpi_u8,
    value: *C.uacpi_u64,
) callconv(.C) C.uacpi_status {
    const mapped_io = @as(*MappedIo, @ptrCast(@alignCast(handle)));
    const port = mapped_io.base + @as(u16, @intCast(offset));

    switch (byte_width) {
        1 => value.* = arch.inb(port),
        2 => value.* = arch.inw(port),
        4 => value.* = arch.inl(port),
        else => return C.UACPI_STATUS_INVALID_ARGUMENT,
    }

    return C.UACPI_STATUS_OK;
}

export fn uacpi_kernel_io_write(
    handle: C.uacpi_handle,
    offset: C.uacpi_size,
    byte_width: C.uacpi_u8,
    value: C.uacpi_u64,
) callconv(.C) C.uacpi_status {
    const mapped_io = @as(*MappedIo, @ptrCast(@alignCast(handle)));
    const port = mapped_io.base + @as(u16, @intCast(offset));

    switch (byte_width) {
        1 => arch.outb(port, @intCast(value)),
        2 => arch.outw(port, @intCast(value)),
        4 => arch.outl(port, @intCast(value)),
        else => return C.UACPI_STATUS_INVALID_ARGUMENT,
    }

    return C.UACPI_STATUS_OK;
}

export fn uacpi_kernel_map(addr: C.uacpi_phys_addr, len: C.uacpi_size) callconv(.C) ?*anyopaque {
    _ = len;
    return pmm.virtualForPhysical(*anyopaque, addr);
}

export fn uacpi_kernel_unmap(addr: *anyopaque, len: C.uacpi_size) callconv(.C) void {
    _ = addr;
    _ = len;
}

export fn uacpi_kernel_alloc(size: C.uacpi_size) callconv(.C) ?*anyopaque {
    return @ptrCast(root.allocator.rawAlloc(@max(size, 8), 3, @returnAddress()).?);
}

export fn uacpi_kernel_calloc(count: C.uacpi_size, size: C.uacpi_size) callconv(.C) ?*anyopaque {
    const result: [*]u8 = @ptrCast(uacpi_kernel_alloc(count * size));
    @memset(result[0 .. count * size], 0);
    return result;
}

export fn uacpi_kernel_free(mem: ?*anyopaque, size_hint: C.uacpi_size) callconv(.C) void {
    if (mem != null) {
        const ptr: [*]u8 = @ptrCast(mem.?);
        root.allocator.rawFree(ptr[0..@max(size_hint, 8)], 3, @returnAddress());
    }
}

export fn uacpi_kernel_log(level: C.uacpi_log_level, msg: [*c]const C.uacpi_char) callconv(.C) void {
    var message = std.mem.span(msg);

    if (message.len > 0 and message[message.len - 1] == '\n') {
        message.len -= 1;
    }

    switch (level) {
        C.UACPI_LOG_DEBUG, C.UACPI_LOG_TRACE => logger.debug("{s}", .{message}),
        C.UACPI_LOG_INFO => logger.info("{s}", .{message}),
        C.UACPI_LOG_WARN => logger.warn("{s}", .{message}),
        C.UACPI_LOG_ERROR => logger.err("{s}", .{message}),
        else => unreachable,
    }
}

export fn uacpi_kernel_get_ticks() callconv(.C) C.uacpi_u64 {
    @panic("uacpi_kernel_get_ticks is unimplemented");
}

export fn uacpi_kernel_stall(usec: C.uacpi_u8) callconv(.C) void {
    _ = usec;
    @panic("uacpi_kernel_stall is unimplemented");
}

export fn uacpi_kernel_sleep(msec: C.uacpi_u64) callconv(.C) void {
    _ = msec;
    @panic("uacpi_kernel_sleep is unimplemented");
}

export fn uacpi_kernel_create_mutex() callconv(.C) C.uacpi_handle {
    logger.warn("uacpi_kernel_create_mutex is implemented as a spinlock", .{});
    return uacpi_kernel_create_spinlock();
}

export fn uacpi_kernel_free_mutex(handle: C.uacpi_handle) callconv(.C) void {
    uacpi_kernel_free_spinlock(handle);
}

export fn uacpi_kernel_acquire_mutex(
    handle: C.uacpi_handle,
    timeout: C.uacpi_u16,
) callconv(.C) C.uacpi_bool {
    std.debug.assert(timeout == 0xffff);
    _ = uacpi_kernel_spinlock_lock(handle);
    return true;
}

export fn uacpi_kernel_release_mutex(handle: C.uacpi_handle) callconv(.C) void {
    uacpi_kernel_spinlock_unlock(handle, 0);
}

export fn uacpi_kernel_create_spinlock() callconv(.C) C.uacpi_handle {
    const spinlock = root.allocator.create(sync.Spinlock) catch unreachable;
    spinlock.* = .{};
    return @ptrCast(spinlock);
}

export fn uacpi_kernel_free_spinlock(handle: C.uacpi_handle) callconv(.C) void {
    root.allocator.destroy(@as(*sync.Spinlock, @ptrCast(@alignCast(handle))));
}

export fn uacpi_kernel_spinlock_lock(handle: C.uacpi_handle) callconv(.C) C.uacpi_cpu_flags {
    const spinlock: *sync.Spinlock = @ptrCast(@alignCast(handle));
    spinlock.lock();
    return 0;
}

export fn uacpi_kernel_spinlock_unlock(
    handle: C.uacpi_handle,
    flags: C.uacpi_cpu_flags,
) callconv(.C) void {
    _ = flags;
    const spinlock: *sync.Spinlock = @ptrCast(@alignCast(handle));
    spinlock.unlock();
}

export fn uacpi_kernel_create_event() callconv(.C) C.uacpi_handle {
    @panic("uacpi_kernel_create_event is unimplemented");
}

export fn uacpi_kernel_free_event(handle: C.uacpi_handle) callconv(.C) void {
    _ = handle;
    @panic("uacpi_kernel_free_event is unimplemented");
}

export fn uacpi_kernel_wait_for_event(
    handle: C.uacpi_handle,
    timeout: C.uacpi_u16,
) callconv(.C) C.uacpi_bool {
    _ = handle;
    _ = timeout;
    @panic("uacpi_kernel_wait_for_event is unimplemented");
}

export fn uacpi_kernel_signal_event(handle: C.uacpi_handle) callconv(.C) void {
    _ = handle;
    @panic("uacpi_kernel_signal_event is unimplemented");
}

export fn uacpi_kernel_reset_event(handle: C.uacpi_handle) callconv(.C) void {
    _ = handle;
    @panic("uacpi_kernel_reset_event is unimplemented");
}

export fn uacpi_kernel_get_thread_id() callconv(.C) C.uacpi_thread_id {
    @panic("uacpi_kernel_get_thread_id is unimplemented");
}

export fn uacpi_kernel_handle_firmware_request(
    request: *C.uacpi_firmware_request,
) callconv(.C) C.uacpi_status {
    _ = request;
    return C.UACPI_STATUS_UNIMPLEMENTED;
}

export fn uacpi_kernel_install_interrupt_handler(
    irq: C.uacpi_u32,
    handler: C.uacpi_interrupt_handler,
    ctx: C.uacpi_handle,
    out_irq_handle: *C.uacpi_handle,
) callconv(.C) C.uacpi_status {
    _ = irq;
    _ = handler;
    _ = ctx;
    _ = out_irq_handle;
    return C.UACPI_STATUS_UNIMPLEMENTED;
}

export fn uacpi_kernel_uninstall_interrupt_handler(
    handler: C.uacpi_interrupt_handler,
    irq_handle: C.uacpi_handle,
) callconv(.C) C.uacpi_status {
    _ = handler;
    _ = irq_handle;
    return C.UACPI_STATUS_UNIMPLEMENTED;
}

export fn uacpi_kernel_schedule_work(
    work_type: C.uacpi_work_type,
    handler: C.uacpi_work_handler,
    ctx: C.uacpi_handle,
) callconv(.C) C.uacpi_status {
    _ = work_type;
    _ = handler;
    _ = ctx;
    return C.UACPI_STATUS_UNIMPLEMENTED;
}

export fn uacpi_kernel_wait_for_work_completion() callconv(.C) C.uacpi_status {
    return C.UACPI_STATUS_UNIMPLEMENTED;
}
