const root = @import("root");
const std = @import("std");

const arch = @import("arch.zig");
const interrupts = @import("interrupts.zig");

const TableDescriptor = packed struct(u80) {
    limit: u16,
    base: u64,
};

const Gdt = struct {
    const Entry = packed struct(u64) {
        limit_low: u16,
        base_low: u16,
        base_middle: u8,
        type_: u4,
        s: bool,
        dpl: u2,
        p: bool,
        limit_high: u4,
        avl: u1,
        l: bool,
        db: bool,
        g: bool,
        base_high: u8,
    };

    entries: [5]Entry = .{
        undefined, // null descriptor
        @bitCast(@as(u64, 0xaf9b000000ffff)), // 64-bit kernel code descriptor
        @bitCast(@as(u64, 0xaf93000000ffff)), // 64-bit kernel data descriptor
        undefined, // tss descriptor (lower part)
        undefined, // tss descriptor (upper part)
    },

    noinline fn load(self: *@This()) void {
        const gdtr: TableDescriptor = .{
            .limit = @sizeOf(@This()) - 1,
            .base = @intFromPtr(self),
        };

        asm volatile (
            \\lgdt (%[gdtr])
            \\push $0x8
            \\lea 1f(%%rip), %%rax
            \\push %%rax
            \\lretq
            \\1:
            \\mov $0x10, %%ax
            \\mov %%ax, %%ds
            \\mov %%ax, %%es
            \\mov %%ax, %%ss
            \\mov %%ax, %%fs
            \\mov %%ax, %%gs
            :
            : [gdtr] "r" (&gdtr),
        );
    }
};

const Idt = struct {
    const Entry = packed struct(u128) {
        offset_low: u16,
        selector: u16,
        ist: u3,
        zero_04_3: u5 = 0,
        type_: u4,
        zero_04_12: u1 = 0,
        dpl: u2,
        p: bool,
        offset_middle: u16,
        offset_high: u32,
        zero_0c: u32 = 0,

        fn init(address: u64, ist: u3, type_: u4, dpl: u2) @This() {
            return .{
                .offset_low = @truncate(address),
                .selector = 0x8,
                .ist = ist,
                .type_ = type_,
                .dpl = dpl,
                .p = true,
                .offset_middle = @truncate(address >> 16),
                .offset_high = @intCast(address >> 32),
            };
        }
    };

    entries: [256]Entry = undefined,

    fn initialize(self: *@This()) void {
        inline for (&self.entries, 0..) |*entry, i| {
            const handler = interrupts.getInterruptHandler(i);
            entry.* = Entry.init(@intFromPtr(handler), 0, 0xe, 0);
        }
    }

    noinline fn load(self: *@This()) void {
        const idtr: TableDescriptor = .{
            .limit = @sizeOf(@This()) - 1,
            .base = @intFromPtr(self),
        };

        asm volatile ("lidt (%[idtr])"
            :
            : [idtr] "r" (&idtr),
        );
    }
};

pub const CpuData = struct {
    self: *CpuData,
    apic_address: u64,

    gdt: Gdt = .{},
    idt: Idt = .{},
};

var bsp_cpu_data: CpuData = undefined;

fn initializeCpu(data: *CpuData) void {
    data.* = .{
        .self = data,
        .apic_address = arch.rdmsr(.ia32_apic_base) & ~@as(u64, 0xfff),
    };

    data.idt.initialize();

    data.gdt.load();
    data.idt.load();

    arch.wrmsr(.ia32_gs_base, @intFromPtr(data));
}

pub fn initializeBsp() void {
    initializeCpu(&bsp_cpu_data);
}

pub fn initialize() void {
    const cpu_data = root.allocator.create(CpuData) catch unreachable;

    initializeCpu(cpu_data);
}

pub inline fn getCpuData() *CpuData {
    return asm volatile ("mov %%gs:0, %[result]"
        : [result] "=r" (-> *CpuData),
    );
}
