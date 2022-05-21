const logger = std.log.scoped(.virt);

const root = @import("root");
const std = @import("std");

const arch = @import("arch.zig");
const limine = @import("limine.zig");
const phys = @import("phys.zig");
const utils = @import("utils.zig");
const vfs = @import("vfs.zig");

const IrqSpinlock = @import("irq_lock.zig").IrqSpinlock;

const flags_mask: u64 = 0xFFF0_0000_0000_0FFF;

pub const Flags = struct {
    pub const None = 0;
    pub const Present = 1 << 0;
    pub const Writable = 1 << 1;
    pub const User = 1 << 2;
    pub const WriteThrough = 1 << 3;
    pub const NoCache = 1 << 4;
    pub const NoExecute = 1 << 63;
};

fn switchPageTable(cr3: u64) void {
    asm volatile ("mov %[cr3], %%cr3"
        :
        : [cr3] "r" (cr3),
        : "memory"
    );
}

fn getPageTable(page_table: *PageTable, index: usize, allocate: bool) ?*PageTable {
    var entry = &page_table.entries[index];

    if (entry.getFlags() & Flags.Present != 0) {
        return @intToPtr(*PageTable, hhdm + entry.getAddress());
    } else if (allocate) {
        const new_page_table = phys.allocate(1, true) orelse return null;

        entry.setAddress(new_page_table);
        entry.setFlags(Flags.Present | Flags.Writable | Flags.User);

        return @intToPtr(*PageTable, hhdm + new_page_table);
    }

    return null;
}

fn virtToIndices(virt: u64) struct { pml4: usize, pml3: usize, pml2: usize, pml1: usize } {
    const pml4 = @as(usize, virt >> 39) & 0x1FF;
    const pml3 = @as(usize, virt >> 30) & 0x1FF;
    const pml2 = @as(usize, virt >> 21) & 0x1FF;
    const pml1 = @as(usize, virt >> 12) & 0x1FF;

    return .{
        .pml4 = pml4,
        .pml3 = pml3,
        .pml2 = pml2,
        .pml1 = pml1,
    };
}

inline fn protToFlags(prot: u64, user: bool) u64 {
    var flags: u64 = Flags.Present;

    if (user)
        flags |= Flags.User;

    if (prot & std.os.linux.PROT.WRITE != 0)
        flags |= Flags.Writable;

    if (prot & std.os.linux.PROT.EXEC == 0)
        flags |= Flags.NoExecute;

    return flags;
}

const PageTableEntry = packed struct {
    value: u64,

    pub fn getAddress(self: *const PageTableEntry) u64 {
        return self.value & ~flags_mask;
    }

    pub fn getFlags(self: *const PageTableEntry) u64 {
        return self.value & flags_mask;
    }

    pub fn setAddress(self: *PageTableEntry, address: u64) void {
        self.value = address | self.getFlags();
    }

    pub fn setFlags(self: *PageTableEntry, flags: u64) void {
        self.value = self.getAddress() | flags;
    }
};

const PageTable = packed struct {
    entries: [512]PageTableEntry,

    pub fn translate(self: *PageTable, virt_addr: u64) ?u64 {
        const indices = virtToIndices(virt_addr);
        const pml3 = getPageTable(self, indices.pml4, false) orelse return null;
        const pml2 = getPageTable(pml3, indices.pml3, false) orelse return null;
        const pml1 = getPageTable(pml2, indices.pml2, false) orelse return null;
        const entry = &pml1.entries[indices.pml1];

        if (entry.getFlags() & Flags.Present != 0) {
            return entry.getAddress();
        } else {
            return null;
        }
    }

    pub fn mapPage(self: *PageTable, virt_addr: u64, phys_addr: u64, flags: u64) !void {
        const indices = virtToIndices(virt_addr);
        const pml3 = getPageTable(self, indices.pml4, true) orelse return error.OutOfMemory;
        const pml2 = getPageTable(pml3, indices.pml3, true) orelse return error.OutOfMemory;
        const pml1 = getPageTable(pml2, indices.pml2, true) orelse return error.OutOfMemory;
        const entry = &pml1.entries[indices.pml1];

        if (entry.getFlags() & Flags.Present != 0) {
            return error.AlreadyMapped;
        } else {
            entry.setAddress(phys_addr);
            entry.setFlags(flags);
        }
    }

    pub fn remapPage(self: *PageTable, virt_addr: u64, phys_addr: u64, flags: u64) !void {
        const indices = virtToIndices(virt_addr);
        const pml3 = getPageTable(self, indices.pml4, false) orelse return error.OutOfMemory;
        const pml2 = getPageTable(pml3, indices.pml3, false) orelse return error.OutOfMemory;
        const pml1 = getPageTable(pml2, indices.pml2, false) orelse return error.OutOfMemory;
        const entry = &pml1.entries[indices.pml1];

        if (entry.getFlags() & Flags.Present != 0) {
            entry.setAddress(phys_addr);
            entry.setFlags(flags);

            asm volatile ("invlpg %[page]"
                :
                : [page] "rm" (virt_addr),
            );
        } else {
            return error.NotMapped;
        }
    }

    pub fn unmapPage(self: *PageTable, virt_addr: u64) !void {
        const indices = virtToIndices(virt_addr);
        const pml3 = getPageTable(self, indices.pml4, false) orelse return error.OutOfMemory;
        const pml2 = getPageTable(pml3, indices.pml3, false) orelse return error.OutOfMemory;
        const pml1 = getPageTable(pml2, indices.pml2, false) orelse return error.OutOfMemory;
        const entry = &pml1.entries[indices.pml1];

        if (entry.getFlags() & Flags.Present != 0) {
            entry.setAddress(0);
            entry.setFlags(.None);

            asm volatile ("invlpg %[page]"
                :
                : [page] "rm" (virt_addr),
            );
        } else {
            return error.NotMapped;
        }
    }

    pub fn map(self: *PageTable, virt_addr: u64, phys_addr: u64, size: usize, flags: u64) !void {
        var i: u64 = 0;

        std.debug.assert(utils.isAligned(u64, virt_addr, std.mem.page_size));
        std.debug.assert(utils.isAligned(u64, phys_addr, std.mem.page_size));
        std.debug.assert(utils.isAligned(u64, size, std.mem.page_size));

        while (i < size) : (i += std.mem.page_size) {
            try self.mapPage(virt_addr + i, phys_addr + i, flags);
        }
    }

    pub fn remap(self: *PageTable, virt_addr: u64, phys_addr: u64, size: usize, flags: u64) !void {
        var i: u64 = 0;

        std.debug.assert(utils.isAligned(u64, virt_addr, std.mem.page_size));
        std.debug.assert(utils.isAligned(u64, phys_addr, std.mem.page_size));
        std.debug.assert(utils.isAligned(u64, size, std.mem.page_size));

        while (i < size) : (i += std.mem.page_size) {
            try self.remapPage(virt_addr + i, phys_addr + i, flags);
        }
    }

    pub fn unmap(self: *PageTable, virt_addr: u64, size: usize) !void {
        var i: u64 = 0;

        std.debug.assert(utils.isAligned(u64, virt_addr, std.mem.page_size));
        std.debug.assert(utils.isAligned(u64, size, std.mem.page_size));

        while (i < size) : (i += std.mem.page_size) {
            try self.unmapPage(virt_addr + i);
        }
    }
};

pub const LoadedExecutable = struct {
    entry: u64,
    ld_path: ?[]const u8,
    aux_vals: struct {
        at_entry: u64,
        at_phdr: u64,
        at_phent: u64,
        at_phnum: u64,
    },
};

pub const FaultReason = struct {
    pub const Present = 1 << 0;
    pub const Write = 1 << 1;
    pub const User = 1 << 2;
    pub const InstructionFetch = 1 << 4;
};

pub const AddressSpace = struct {
    cr3: u64,
    page_table: *PageTable,
    lock: IrqSpinlock = .{},

    pub fn init(cr3: u64) AddressSpace {
        return .{
            .cr3 = cr3,
            .page_table = @intToPtr(*PageTable, hhdm + cr3),
        };
    }

    pub fn switchTo(self: *AddressSpace) *AddressSpace {
        _ = paging_lock.lock();

        defer paging_lock.unlock();

        if (current_address_space) |previous| {
            if (self == previous) {
                return self;
            }

            current_address_space = self;

            switchPageTable(self.cr3);

            return previous;
        } else {
            current_address_space = self;

            switchPageTable(self.cr3);

            return self;
        }
    }

    pub fn loadExecutable(self: *AddressSpace, file: *vfs.VNode, base: u64) !LoadedExecutable {
        var stream = file.stream();
        var header = try std.elf.Header.read(&stream);
        var ph_iter = header.program_header_iterator(&stream);
        var ld_path: ?[]const u8 = null;
        var entry: u64 = header.entry + base;
        var phdr: u64 = 0;

        while (try ph_iter.next()) |ph| {
            switch (ph.p_type) {
                std.elf.PT_INTERP => ld_path = try root.allocator.alloc(u8, ph.p_filesz),
                std.elf.PT_PHDR => phdr = ph.p_vaddr + base,
                std.elf.PT_LOAD => {
                    const misalign = ph.p_vaddr & (std.mem.page_size - 1);
                    const page_count = utils.divRoundUp(u64, misalign + ph.p_memsz, std.mem.page_size);
                    const page_phys = phys.allocate(page_count, true) orelse return error.OutOfMemory;
                    const page_hh = @intToPtr([*]u8, hhdm + page_phys + misalign);

                    var flags: u64 = Flags.Present | Flags.User;

                    if (ph.p_flags & std.elf.PF_W != 0)
                        flags |= Flags.Writable;

                    if (ph.p_flags & std.elf.PF_X == 0)
                        flags |= Flags.NoExecute;

                    const virt_addr = utils.alignDown(u64, ph.p_vaddr, std.mem.page_size) + base;

                    try self.page_table.map(virt_addr, page_phys, page_count * std.mem.page_size, flags);

                    _ = try file.read(page_hh[0..ph.p_filesz], ph.p_offset);
                },
                else => continue,
            }
        }

        return LoadedExecutable{
            .entry = entry,
            .ld_path = ld_path,
            .aux_vals = .{
                .at_entry = entry,
                .at_phdr = phdr,
                .at_phent = header.phentsize,
                .at_phnum = header.phnum,
            },
        };
    }
};

pub var hhdm: u64 = 0;
pub var kernel_address_space: ?AddressSpace = null;

var paging_lock: IrqSpinlock = .{};
var current_address_space: ?*AddressSpace = null;

fn map_section(
    comptime section_name: []const u8,
    page_table: *PageTable,
    kernel_addr_res: *limine.KernelAddress.Response,
    flags: u64,
) !void {
    const begin = @extern(*u8, .{ .name = section_name ++ "_begin" });
    const end = @extern(*u8, .{ .name = section_name ++ "_end" });

    const virt_base = @ptrToInt(begin);
    const phys_base = virt_base - kernel_addr_res.virtual_base + kernel_addr_res.physical_base;
    const size = utils.alignUp(usize, @ptrToInt(end) - @ptrToInt(begin), std.mem.page_size);

    try page_table.map(virt_base, phys_base, size, flags);
}

pub fn init(hhdm_res: *limine.Hhdm.Response, kernel_addr_res: *limine.KernelAddress.Response) !void {
    hhdm = hhdm_res.offset;

    const page_table_phys = phys.allocate(1, true) orelse return error.OutOfMemory;
    const page_table = @intToPtr(*PageTable, hhdm + page_table_phys);

    // Pre-populate the higher half of kernel address space
    var i: usize = 256;

    while (i < 512) : (i += 1) {
        _ = getPageTable(page_table, i, true);
    }

    try page_table.map(std.mem.page_size, std.mem.page_size, utils.gib(4) - std.mem.page_size, Flags.Present | Flags.Writable);
    try page_table.map(hhdm, 0, utils.gib(4), Flags.Present | Flags.Writable);

    try map_section("text", page_table, kernel_addr_res, Flags.Present);
    try map_section("rodata", page_table, kernel_addr_res, Flags.Present | Flags.NoExecute);
    try map_section("data", page_table, kernel_addr_res, Flags.Present | Flags.NoExecute | Flags.Writable);

    // Prepare for the address space switch
    kernel_address_space = AddressSpace.init(page_table_phys);

    _ = kernel_address_space.?.switchTo();
}

pub fn createAddressSpace() !AddressSpace {
    var page_table_phys = phys.allocate(1, true) orelse return error.OutOfMemory;
    var address_space = AddressSpace.init(page_table_phys);

    var i: usize = 256;

    while (i < 512) : (i += 1) {
        address_space.page_table.entries[i] = kernel_address_space.?.page_table.entries[i];
    }

    return address_space;
}
