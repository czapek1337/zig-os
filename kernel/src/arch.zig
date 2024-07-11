pub inline fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "N{dx}" (port),
    );
}

pub inline fn outw(port: u16, value: u16) void {
    asm volatile ("outw %[value], %[port]"
        :
        : [value] "{ax}" (value),
          [port] "N{dx}" (port),
    );
}

pub inline fn outl(port: u16, value: u32) void {
    asm volatile ("outl %[value], %[port]"
        :
        : [value] "{eax}" (value),
          [port] "N{dx}" (port),
    );
}

pub inline fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[value]"
        : [value] "={al}" (-> u8),
        : [port] "N{dx}" (port),
    );
}

pub inline fn inw(port: u16) u16 {
    return asm volatile ("inw %[port], %[value]"
        : [value] "={ax}" (-> u16),
        : [port] "N{dx}" (port),
    );
}

pub inline fn inl(port: u16) u32 {
    return asm volatile ("inl %[port], %[value]"
        : [value] "={eax}" (-> u32),
        : [port] "N{dx}" (port),
    );
}

pub const CpuIdResult = packed struct(u128) {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
};

pub inline fn cpuid(eax: u32, ecx: u32) CpuIdResult {
    var a: u32 = 0;
    var b: u32 = 0;
    var c: u32 = 0;
    var d: u32 = 0;
    asm volatile ("cpuid"
        : [_] "={eax}" (a),
          [_] "={ebx}" (b),
          [_] "={ecx}" (c),
          [_] "={edx}" (d),
        : [_] "{eax}" (eax),
          [_] "{ebx}" (ecx),
    );
    return .{ .eax = a, .ebx = b, .ecx = c, .edx = d };
}

pub const Msr = enum(u32) {
    ia32_apic_base = 0x1b,
    ia32_tsc_deadline = 0x6e0,
    ia32_fs_base = 0xc0000100,
    ia32_gs_base = 0xc0000101,
    ia32_kernel_gs_base = 0xc0000102,
};

pub inline fn rdmsr(msr: Msr) u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdmsr"
        : [_] "={eax}" (low),
          [_] "={edx}" (high),
        : [_] "{ecx}" (@intFromEnum(msr)),
    );
    return (@as(u64, high) << 32) | low;
}

pub inline fn wrmsr(msr: Msr, value: u64) void {
    asm volatile ("wrmsr"
        :
        : [_] "{ecx}" (@intFromEnum(msr)),
          [_] "{eax}" (value & 0xffffffff),
          [_] "{edx}" (value >> 32),
    );
}

pub inline fn rdtsc() u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdtsc"
        : [_] "={eax}" (low),
          [_] "={edx}" (high),
    );
    return (@as(u64, high) << 32) | low;
}
