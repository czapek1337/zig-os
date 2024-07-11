const logger = std.log.scoped(.main);

const limine = @import("limine");
const std = @import("std");

const acpi = @import("acpi.zig");
const apic = @import("apic.zig");
const arch = @import("arch.zig");
const cpu = @import("cpu.zig");
const hpet = @import("hpet.zig");
const pmm = @import("pmm.zig");
const sync = @import("sync.zig");
const time = @import("time.zig");
const vmm = @import("vmm.zig");

export var base_revision: limine.BaseRevision = .{ .revision = 2 };

export fn _start() callconv(.C) noreturn {
    std.debug.assert(base_revision.is_supported());

    pmm.initialize();
    cpu.initializeBsp();
    vmm.initialize();
    acpi.initialize();
    hpet.initialize();
    apic.initialize();
    time.initialize();

    asm volatile ("sti");

    logger.info("hello {s}!", .{"world"});

    const timer = time.createTimer() catch unreachable;

    while (true) {
        timer.arm(time.currentNanos() + std.time.ns_per_ms * 10) catch unreachable;
        asm volatile ("hlt");
        logger.info("timer fired, current time is {d} ms", .{time.currentNanos() / std.time.ns_per_ms});
    }
}

pub fn panic(msg: []const u8, stack_trace: ?*std.builtin.StackTrace, return_addr: ?usize) noreturn {
    logger.err("kernel panic: {s}", .{msg});

    if (return_addr) |addr| {
        logger.err("  return address: 0x{x}", .{addr});
    }

    if (stack_trace) |trace| {
        logger.err("stack trace:", .{});

        var i: usize = 0;
        var frame_index: usize = 0;
        var frames_left: usize = @min(trace.index, trace.instruction_addresses.len);

        while (frames_left != 0) : ({
            frames_left -= 1;
            frame_index = (frame_index + 1) % trace.instruction_addresses.len;
            i += 1;
        }) {
            logger.err("  {d}: 0x{x}", .{ i, trace.instruction_addresses[frame_index] });
        }
    } else {
        logger.err("no stack trace available", .{});
    }

    while (true) {
        asm volatile ("hlt");
    }
}

pub var gp_allocator: std.heap.GeneralPurposeAllocator(.{
    .thread_safe = true,
    .MutexType = sync.Spinlock,
}) = .{};

pub var allocator = gp_allocator.allocator();

pub const std_options: std.Options = .{
    .logFn = log,
    .log_level = .debug,
};

pub const os = struct {
    pub const heap = struct {
        pub const page_allocator: std.mem.Allocator = .{
            .ptr = &page_allocator_,
            .vtable = &.{
                .alloc = PageAllocator.alloc,
                .resize = PageAllocator.resize,
                .free = PageAllocator.free,
            },
        };
    };
};

var page_allocator_: PageAllocator = .{};

const PageAllocator = struct {
    base: u64 = 0xffff_9000_0000_0000,

    fn alloc(ctx: *anyopaque, len: usize, _: u8, _: usize) ?[*]u8 {
        const self: *PageAllocator = @ptrCast(@alignCast(ctx));
        const pages = std.math.divCeil(usize, len, std.mem.page_size) catch unreachable;

        const address = self.base;
        const length = pages * std.mem.page_size;
        const page_frame = pmm.allocatePage(pmm.orderForSize(length), .kernel) orelse return null;

        errdefer pmm.freePage(page_frame);

        vmm.getKernelAddressSpace().page_table.mapRange(
            address,
            page_frame.getAddress(),
            length,
            vmm.pte_rw | vmm.pte_xd,
        ) catch return null;

        self.base += length;

        return @ptrFromInt(address);
    }

    fn resize(_: *anyopaque, _: []u8, _: u8, _: usize, _: usize) bool {
        return false;
    }

    fn free(_: *anyopaque, _: []u8, _: u8, _: usize) void {}
};

const LogWriter = struct {
    pub const Error = error{};

    pub fn write(self: @This(), bytes: []const u8) Error!usize {
        for (bytes) |byte| {
            try self.writeByte(byte);
        }

        return bytes.len;
    }

    pub fn writeByte(_: @This(), byte: u8) Error!void {
        arch.outb(0xe9, byte);
    }

    pub fn writeBytesNTimes(self: @This(), bytes: []const u8, n: usize) Error!void {
        for (0..n) |_| {
            _ = try self.write(bytes);
        }
    }

    pub fn writeAll(self: @This(), bytes: []const u8) Error!void {
        _ = try self.write(bytes);
    }
};

fn log(comptime level: std.log.Level, comptime scope: anytype, comptime fmt: []const u8, args: anytype) void {
    const writer: LogWriter = undefined;

    std.fmt.format(
        writer,
        "{s}({s}): " ++ fmt ++ "\n",
        .{ @tagName(level), @tagName(scope) } ++ args,
    ) catch unreachable;
}
