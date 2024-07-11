const std = @import("std");

const IretFrame = extern struct {
    err: u64,
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

pub const InterruptFrame = extern struct {
    es: u64,
    ds: u64,
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rsi: u64,
    rdi: u64,
    rbp: u64,
    rdx: u64,
    rcx: u64,
    rbx: u64,
    rax: u64,
    vector: u64,
    iret: IretFrame,
};

const InterruptHandler = *const fn (*InterruptFrame) callconv(.C) void;

export var __interrupt_handlers: [256]InterruptHandler =
    [1]InterruptHandler{exceptionHandler} ** 32 ++ [1]InterruptHandler{unhandledHandler} ** 224;

export fn __common_interrupt_handler() callconv(.Naked) void {
    const handler_code = std.fmt.comptimePrint(
        \\push %rax
        \\push %rbx
        \\push %rcx
        \\push %rdx
        \\push %rbp
        \\push %rdi
        \\push %rsi
        \\push %r8
        \\push %r9
        \\push %r10
        \\push %r11
        \\push %r12
        \\push %r13
        \\push %r14
        \\push %r15
        \\mov %ds, %eax
        \\push %rax
        \\mov %es, %eax
        \\push %rax
        \\mov %rsp, %rdi
        \\mov {d}(%%rsp), %rax
        \\call *__interrupt_handlers(, %rax, 8)
        \\pop %rax
        \\mov %ax, %es
        \\pop %rax
        \\mov %ax, %ds
        \\pop %r15
        \\pop %r14
        \\pop %r13
        \\pop %r12
        \\pop %r11
        \\pop %r10
        \\pop %r9
        \\pop %r8
        \\pop %rsi
        \\pop %rdi
        \\pop %rbp
        \\pop %rdx
        \\pop %rcx
        \\pop %rbx
        \\pop %rax
        \\add $16, %rsp
        \\iretq
    , .{@offsetOf(InterruptFrame, "vector")});

    asm volatile (handler_code);
}

var vector_counter: u8 = 32;

pub inline fn registerHandler(vector: u8, handler: InterruptHandler) void {
    std.debug.assert(vector > 31);

    __interrupt_handlers[vector] = handler;
}

pub inline fn allocateVector() u8 {
    std.debug.assert(vector_counter < 255);

    return @atomicRmw(u8, &vector_counter, .Add, 1, .seq_cst);
}

pub fn getInterruptHandler(comptime vector: u8) *const fn () callconv(.Naked) void {
    // const swapgs_if_needed = std.fmt.comptimePrint(
    //     \\testb $3, {d}(%%rsp)
    //     \\je 1f
    //     \\swapgs
    //     \\1:
    // , .{@offsetOf(IretFrame, "cs")});

    const handler_code = std.fmt.comptimePrint(
        \\pushq ${d}
        \\jmp __common_interrupt_handler
    , .{vector});

    const has_error_code = switch (vector) {
        0x8, 0xa...0xe, 0x11, 0x15 => true,
        else => false,
    };

    const wrapper = struct {
        fn handler() callconv(.Naked) void {
            // asm volatile (swapgs_if_needed);

            if (!has_error_code) {
                asm volatile ("pushq $0");
            }

            asm volatile (handler_code);
        }
    };

    return &wrapper.handler;
}

fn exceptionHandler(frame: *InterruptFrame) callconv(.C) void {
    std.debug.panic("unhandled exception {d}", .{frame.vector});
}

fn unhandledHandler(frame: *InterruptFrame) callconv(.C) void {
    std.debug.panic("unhandled interrupt {d}", .{frame.vector});
}
