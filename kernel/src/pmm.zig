const logger = std.log.scoped(.pmm);

const limine = @import("limine");
const std = @import("std");

const sync = @import("sync.zig");

pub const PageFrameUsage = enum(u3) {
    invalid,
    pfn_database,
    kernel,
    usable,
    page_table,
};

pub const PageFrame = struct {
    list_node: std.SinglyLinkedList(void).Node = .{ .data = {} },
    info: packed struct(u64) {
        pfn: u52,
        order: u6,
        usage: PageFrameUsage,
        on_freelist: bool,
        _dummy: u2,
    },

    pub fn init(addr: u64, frame_usage: PageFrameUsage) @This() {
        return .{ .info = .{
            .pfn = @intCast(addr >> 12),
            .order = 0,
            .usage = frame_usage,
            .on_freelist = false,
            ._dummy = undefined,
        } };
    }

    pub fn getRegion(self: @This()) *PhysicalMemoryRegion {
        for (memory_regions) |*region| {
            if (region.contains(self.getAddress())) {
                return region;
            }
        }

        unreachable;
    }

    pub inline fn getAddress(self: @This()) u64 {
        return @as(u64, self.info.pfn) << 12;
    }
};

const PhysicalMemoryRegion = struct {
    list_node: std.TailQueue(void).Node = .{ .data = {} },
    base: u64,
    page_count: usize,
    _dummy: [0]PageFrame,

    pub fn init(base: u64, page_count: usize) @This() {
        return .{
            .base = base,
            .page_count = page_count,
            ._dummy = undefined,
        };
    }

    pub inline fn getIndex(self: *@This(), frame: *PageFrame) usize {
        return @divExact(@intFromPtr(frame) - @intFromPtr(&self._dummy), @sizeOf(PageFrame));
    }

    pub inline fn getEndAddress(self: @This()) u64 {
        return self.base + self.page_count * std.mem.page_size;
    }

    pub inline fn getPageFrames(self: *@This()) []PageFrame {
        return @as([*]PageFrame, @ptrCast(&self._dummy))[0..self.page_count];
    }

    pub inline fn contains(self: @This(), address: u64) bool {
        return address >= self.base and address < self.getEndAddress();
    }
};

export var memory_map_request: limine.MemoryMapRequest = .{};
export var hhdm_request: limine.HhdmRequest = .{};

var hhdm_offset: u64 = 0;
var memory_regions: std.TailQueue(void) = .{};
var buddies = std.mem.zeroes([16]std.SinglyLinkedList(void));
var lock: sync.Spinlock = .{};

pub fn initialize() void {
    const memory_map_response = memory_map_request.response.?;
    const hhdm_response = hhdm_request.response.?;

    hhdm_offset = hhdm_response.offset;

    logger.info("higher half virtual memory offset is 0x{x}", .{hhdm_offset});
    logger.info("page frame struct size is {d} bytes", .{@sizeOf(PageFrame)});

    for (memory_map_response.entries()) |entry| {
        logger.info(
            "memory entry 0x{x}-0x{x}, {s}, {d}KiB",
            .{ entry.base, entry.base + entry.length, @tagName(entry.kind), entry.length / 1024 },
        );

        if (entry.kind == .usable) {
            trackRegion(entry.base, entry.length);
        }
    }
}

pub fn trackRegion(base: u64, length: usize) void {
    const region: *PhysicalMemoryRegion = @ptrFromInt(base + hhdm_offset);
    const page_count = @divExact(length, std.mem.page_size);
    const reserved_page_count = std.math.divCeil(
        usize,
        @sizeOf(PhysicalMemoryRegion) + page_count * @sizeOf(PageFrame),
        std.mem.page_size,
    ) catch unreachable;

    if (reserved_page_count >= page_count) {
        return;
    }

    region.* = PhysicalMemoryRegion.init(base, page_count);

    logger.info(
        "tracking memory region 0x{x}-0x{x}, {d} pages, {d}KiB usable, {d}KiB reserved",
        .{ region.base, region.getEndAddress(), region.page_count, length / 1024, (reserved_page_count * std.mem.page_size) / 1024 },
    );

    logger.debug("region reserved for page frames is 0x{x}-0x{x}", .{ base, base + reserved_page_count * std.mem.page_size });

    const page_frames = region.getPageFrames();

    for (page_frames, 0..) |*frame, i| {
        frame.* = PageFrame.init(base + i * std.mem.page_size, .invalid);
    }

    for (page_frames[0..reserved_page_count]) |*frame| {
        frame.info.usage = .pfn_database;
    }

    for (page_frames[reserved_page_count..]) |*frame| {
        var order = @min(@ctz(frame.info.pfn), buddies.len - 1);

        while (frame.getAddress() + (@as(u64, 1) << order) * std.mem.page_size > region.getEndAddress()) {
            order -= 1;
        }

        frame.info.usage = .usable;
        frame.info.order = order;
    }

    var i = reserved_page_count;

    while (i < page_count) {
        const frame = &page_frames[i];

        logger.debug("usable page frame 0x{x} has order #{d}", .{ frame.getAddress(), frame.info.order });

        frame.info.on_freelist = true;
        buddies[frame.info.order].prepend(&frame.list_node);

        i += @as(u64, 1) << frame.info.order;
    }

    memory_regions.append(&region.list_node);
}

pub fn orderForSize(size: usize) u6 {
    return @min(
        @ctz(std.math.ceilPowerOfTwo(usize, @max(size, std.mem.page_size)) catch unreachable) - 12,
        buddies.len - 1,
    );
}

pub fn allocatePage(desired_order: u6, usage: PageFrameUsage) ?*PageFrame {
    lock.lock();
    defer lock.unlock();

    var order = desired_order;

    while (buddies[order].first == null) {
        if (order == buddies.len - 1) {
            logger.debug("ran out of memory while trying to allocate a page of order #{d}", .{desired_order});
            return null;
        }

        order += 1;
    }

    while (order > desired_order) {
        const page_frame: *PageFrame = @fieldParentPtr("list_node", buddies[order].popFirst().?);
        const buddy = &@as([*]PageFrame, @ptrCast(page_frame))[@as(u64, 1) << (order - 1)];

        std.debug.assert(buddy.info.order == order - 1);
        std.debug.assert(!buddy.info.on_freelist);

        buddies[order - 1].prepend(&page_frame.list_node);
        buddies[order - 1].prepend(&buddy.list_node);

        page_frame.info.order -= 1;
        buddy.info.on_freelist = true;

        order -= 1;
    }

    const length = (@as(u64, 1) << desired_order) * std.mem.page_size;
    const page_frame: *PageFrame = @fieldParentPtr("list_node", buddies[order].popFirst().?);
    const page_ptr = virtualForPhysical([*]u8, page_frame.getAddress())[0..length];

    std.debug.assert(page_frame.info.order == desired_order);

    page_frame.info.on_freelist = false;
    page_frame.info.usage = usage;

    @memset(page_ptr, 0);

    return page_frame;
}

pub fn freePage(page_frame: *PageFrame) void {
    lock.lock();
    defer lock.unlock();

    const region = page_frame.getRegion();
    var frame = page_frame;

    while (true) {
        const index = region.getIndex(frame);

        var buddy_index: usize = undefined;
        if (index % ((1 << frame.info.order) * 2) != 0) {
            if (index < (1 << frame.info.order)) {
                break;
            }

            buddy_index = index - (1 << frame.info.order);
        } else {
            buddy_index = index + (1 << frame.info.order);
        }

        if (buddy_index >= region.page_count) {
            break;
        }

        const buddy = &region.getPageFrames()[buddy_index];

        if (buddy.info.order != frame.info.order or !buddy.info.on_freelist) {
            break;
        }

        buddies[frame.info.order].remove(&buddy.list_node);

        if (buddy_index < index) {
            frame = buddy;
        }

        frame.info.order += 1;
    }

    buddies[frame.info.order].prepend(&frame.list_node);

    frame.info.on_freelist = true;
    frame.info.usage = .usable;
}

pub fn findPageFrame(addr: u64) ?*PageFrame {
    for (memory_regions) |*region| {
        if (!region.contains(addr)) {
            continue;
        }

        return &region.pageFrames()[(addr - region.base) / std.mem.page_size];
    }

    return null;
}

pub fn virtualForPhysical(comptime T: type, addr: u64) T {
    const type_info = @typeInfo(T);

    if (type_info == .Pointer) {
        return @ptrFromInt(addr + hhdm_offset);
    } else {
        return addr + hhdm_offset;
    }
}
