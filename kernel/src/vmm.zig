const logger = std.log.scoped(.vmm);

const limine = @import("limine");
const std = @import("std");

const arch = @import("arch.zig");
const pmm = @import("pmm.zig");

pub const pte_p: u64 = 1 << 0;
pub const pte_rw: u64 = 1 << 1;
pub const pte_us: u64 = 1 << 2;
pub const pte_ps: u64 = 1 << 7;
pub const pte_xd: u64 = 1 << 63;

const pte_address_mask: u64 = 0x000ffffffffff000;

const two_mib = 1024 * 1024 * 2;
const one_gib = 1024 * 1024 * 1024;

const PageTableEntry = extern struct {
    raw: u64,

    inline fn getAddress(self: @This()) u64 {
        return self.raw & pte_address_mask;
    }

    inline fn getFlags(self: @This()) u64 {
        return self.raw & ~pte_address_mask;
    }

    inline fn setAddress(self: *@This(), addr: u64) void {
        self.raw = self.getFlags() | (addr & pte_address_mask);
    }

    inline fn setFlags(self: *@This(), flags: u64) void {
        self.raw = self.getAddress() | (flags & ~pte_address_mask);
    }
};

fn meetsAlignment(phys: u64, virt: u64, alignment: u64) bool {
    return std.mem.isAlignedGeneric(u64, phys, alignment) and std.mem.isAlignedGeneric(u64, virt, alignment);
}

const PageTable = extern struct {
    entries: [512]PageTableEntry,

    inline fn getEntry(self: *@This(), index: u9) *PageTableEntry {
        return &self.entries[index];
    }

    fn getPageTable(self: *@This(), index: u9, allocate_missing: bool) ?*PageTable {
        const entry = self.getEntry(index);

        if ((entry.getFlags() & pte_p) == 0) {
            if (!allocate_missing) {
                return null;
            }

            const page = pmm.allocatePage(0, .page_table) orelse return null;

            entry.setAddress(page.getAddress());
            entry.setFlags(pte_p | pte_rw | pte_us);
        }

        return pmm.virtualForPhysical(*PageTable, entry.getAddress());
    }

    pub fn mapPage(self: *@This(), address: u64, phys: u64, flags: u64) !void {
        const pml4_index: u9 = @truncate(address >> 39);
        const pdpt_index: u9 = @truncate(address >> 30);
        const pd_index: u9 = @truncate(address >> 21);
        const pt_index: u9 = @truncate(address >> 12);

        const pdpt = self.getPageTable(pml4_index, true) orelse return error.OutOfMemory;
        const pd = pdpt.getPageTable(pdpt_index, true) orelse return error.OutOfMemory;
        const pt = pd.getPageTable(pd_index, true) orelse return error.OutOfMemory;
        const entry = pt.getEntry(pt_index);

        if ((entry.getFlags() & pte_p) != 0) {
            return error.AlreadyMapped;
        }

        entry.setAddress(phys);
        entry.setFlags(flags | pte_p);
    }

    pub fn mapRange(self: *@This(), address: u64, phys: u64, length: usize, flags: u64) !void {
        var remaining_length = length;
        var virtual_address = address;
        var physical_address = phys;

        // errdefer {
        //     const mapped_length = length - remaining_length;
        //
        //     if (remaining_length != 0) {
        //         self.unmapRange(virtual_address, mapped_length);
        //     }
        // }

        while (remaining_length >= std.mem.page_size) {
            var increment: usize = std.mem.page_size;

            if (giant_pages_supported and remaining_length >= one_gib and meetsAlignment(physical_address, virtual_address, one_gib)) {
                const pml4_index: u9 = @truncate(virtual_address >> 39);
                const pdpt_index: u9 = @truncate(virtual_address >> 30);

                const pdpt = self.getPageTable(pml4_index, true) orelse return error.OutOfMemory;
                const entry = pdpt.getEntry(pdpt_index);

                if ((entry.getFlags() & pte_p) != 0) {
                    if ((entry.getFlags() & pte_ps) != 0) {
                        return error.AlreadyMapped;
                    }

                    @panic("TODO: break up the giant page into smaller pages and retry with 2MiB pages");
                }

                entry.setAddress(physical_address);
                entry.setFlags(flags | pte_p | pte_ps);

                increment = one_gib;
            } else if (remaining_length >= two_mib and meetsAlignment(physical_address, virtual_address, two_mib)) {
                const pml4_index: u9 = @truncate(virtual_address >> 39);
                const pdpt_index: u9 = @truncate(virtual_address >> 30);
                const pd_index: u9 = @truncate(virtual_address >> 21);

                const pdpt = self.getPageTable(pml4_index, true) orelse return error.OutOfMemory;
                const pd = pdpt.getPageTable(pdpt_index, true) orelse return error.OutOfMemory;
                const entry = pd.getEntry(pd_index);

                if ((entry.getFlags() & pte_p) != 0) {
                    if ((entry.getFlags() & pte_ps) != 0) {
                        return error.AlreadyMapped;
                    }

                    @panic("TODO: break up the 2MiB page into smaller pages and retry with 4KiB pages");
                }

                entry.setAddress(physical_address);
                entry.setFlags(flags | pte_p | pte_ps);

                increment = two_mib;
            } else {
                try self.mapPage(virtual_address, physical_address, flags);
            }

            remaining_length -= increment;
            virtual_address += increment;
            physical_address += increment;
        }

        std.debug.assert(remaining_length == 0);
        std.debug.assert(virtual_address == address + length);
        std.debug.assert(physical_address == phys + length);
    }
};

pub const Mapping = struct {
    list_node: std.TailQueue(void).Node = .{ .data = {} },
    base: u64,
    length: usize,
    initial_protection: u64,
    protection: u64,
};

pub const AddressSpace = struct {
    cr3: *pmm.PageFrame,
    page_table: *PageTable,
    mappings: std.TailQueue(void) = .{},
};

export var kernel_address_request: limine.KernelAddressRequest = .{};

var giant_pages_supported: bool = false;
var kernel_address_space: AddressSpace = undefined;

pub fn initialize() void {
    const cpuid_result = arch.cpuid(0x80000001, 0);

    if ((cpuid_result.edx & (1 << 26)) != 0) {
        logger.debug("giant pages (1GiB pages) are supported on this system", .{});
        giant_pages_supported = true;
    }

    const kernel_address_response = kernel_address_request.response.?;

    const kernel_page_table = pmm.allocatePage(0, .page_table) orelse
        @panic("Failed to allocate page table for kernel address space");

    logger.info("allocated kernel page table at 0x{x}", .{kernel_page_table.getAddress()});

    kernel_address_space = .{
        .cr3 = kernel_page_table,
        .page_table = pmm.virtualForPhysical(*PageTable, kernel_page_table.getAddress()),
    };

    const text_start = @extern([*]u8, .{ .name = "__text_start" });
    const text_end = @extern([*]u8, .{ .name = "__text_end" });
    const text_base = std.mem.alignBackward(u64, @intFromPtr(text_start), std.mem.page_size);
    const text_length = std.mem.alignForward(usize, @intFromPtr(text_end) - text_base, std.mem.page_size);

    const rodata_start = @extern([*]u8, .{ .name = "__rodata_start" });
    const rodata_end = @extern([*]u8, .{ .name = "__rodata_end" });
    const rodata_base = std.mem.alignBackward(u64, @intFromPtr(rodata_start), std.mem.page_size);
    const rodata_length = std.mem.alignForward(usize, @intFromPtr(rodata_end) - rodata_base, std.mem.page_size);

    const data_start = @extern([*]u8, .{ .name = "__data_start" });
    const data_end = @extern([*]u8, .{ .name = "__data_end" });
    const data_base = std.mem.alignBackward(u64, @intFromPtr(data_start), std.mem.page_size);
    const data_length = std.mem.alignForward(usize, @intFromPtr(data_end) - data_base, std.mem.page_size);

    const text_physical_base = text_base - kernel_address_response.virtual_base + kernel_address_response.physical_base;
    const rodata_physical_base = rodata_base - kernel_address_response.virtual_base + kernel_address_response.physical_base;
    const data_physical_base = data_base - kernel_address_response.virtual_base + kernel_address_response.physical_base;

    kernel_address_space.page_table.mapRange(text_base, text_physical_base, text_length, 0) catch |err| {
        std.debug.panic("failed to map kernel text segment: {any}", .{err});
    };

    kernel_address_space.page_table.mapRange(rodata_base, rodata_physical_base, rodata_length, pte_xd) catch |err| {
        std.debug.panic("failed to map kernel rodata segment: {any}", .{err});
    };

    kernel_address_space.page_table.mapRange(data_base, data_physical_base, data_length, pte_rw | pte_xd) catch |err| {
        std.debug.panic("failed to map kernel data segment: {any}", .{err});
    };

    kernel_address_space.page_table.mapRange(pmm.virtualForPhysical(u64, 0), 0, one_gib * 4, pte_rw | pte_xd) catch |err| {
        std.debug.panic("failed to map the first 4GiB of physical memory: {any}", .{err});
    };

    asm volatile ("mov %[cr3], %%cr3"
        :
        : [cr3] "r" (kernel_address_space.cr3.getAddress()),
        : "memory"
    );
}

pub fn getKernelAddressSpace() *AddressSpace {
    return &kernel_address_space;
}
