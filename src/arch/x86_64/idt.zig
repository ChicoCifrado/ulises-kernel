const std = @import("std");
const c_callconv: std.lang.CallingConvention = std.lang.CallingConvention.c;

pub const IdtEntry = packed struct(u128) {
    offset_low: u16,
    selector: u16,
    ist: u3 = 0,
    _reserved1: u5 = 0,
    gate_type: u4,
    _reserved2: u1 = 0,
    dpl: u2,
    present: u1,
    offset_mid: u16,
    offset_high: u32,
    _reserved3: u32 = 0,
};

pub const IdtPtr = packed struct(u80) {
    limit: u16,
    base: u64,
};

pub const GateType = enum(u4) {
    interrupt = 0xE,
    trap = 0xF,
};

pub const InterruptFrame = packed struct {
    rdi: u64,
    rsi: u64,
    rdx: u64,
    rcx: u64,
    r8: u64,
    r9: u64,
    r10: u64,
    r11: u64,
    rbx: u64,
    rbp: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,
    vector: u64,
    error_code: u64,
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

const NUM_VECTORS = 256;

fn hasErrorCode(vector: u8) bool {
    return switch (vector) {
        8, 10, 11, 12, 13, 14, 17, 21, 29, 30 => true,
        else => false,
    };
}

export var idt: [NUM_VECTORS]IdtEntry align(16) linksection(".data.idt") = @splat(@bitCast(@as(u128, 0)));
export var common_handler_fn: ?*const fn (*const InterruptFrame) callconv(c_callconv) u64 = null;

export fn isrCommon() callconv(.naked) void {
    asm volatile (
        \\pushq %%r15
        \\pushq %%r14
        \\pushq %%r13
        \\pushq %%r12
        \\pushq %%rbp
        \\pushq %%rbx
        \\pushq %%r11
        \\pushq %%r10
        \\pushq %%r9
        \\pushq %%r8
        \\pushq %%rcx
        \\pushq %%rdx
        \\pushq %%rsi
        \\pushq %%rdi
        \\movq %%rsp, %%rdi
        \\cld
        \\movq %[handler_ptr], %%r11
        \\movq (%%r11), %%r11
        \\callq *%%r11
        \\movq %%rax, %%rsp
        \\popq %%rdi
        \\popq %%rsi
        \\popq %%rdx
        \\popq %%rcx
        \\popq %%r8
        \\popq %%r9
        \\popq %%r10
        \\popq %%r11
        \\popq %%rbx
        \\popq %%rbp
        \\popq %%r12
        \\popq %%r13
        \\popq %%r14
        \\popq %%r15
        \\addq $16, %%rsp
        \\iretq
        :
        : [handler_ptr] "r" (&common_handler_fn),
        : .{ .r11 = true, .memory = true }
    );
}

export fn idtLoad() void {
    const ptr = IdtPtr{
        .limit = @sizeOf(@TypeOf(idt)) - 1,
        .base = @intFromPtr(&idt),
    };
    asm volatile ("mov %[ptr], %%rdi\n\tlidtq (%%rdi)"
        :
        : [ptr] "r" (&ptr),
        : .{ .rdi = true, .memory = true }
    );
}

const stubs: [NUM_VECTORS]*const fn () callconv(.naked) void = blk: {
    @setEvalBranchQuota(200000);
    var result: [NUM_VECTORS]*const fn () callconv(.naked) void = undefined;
    var tmp: [10]u8 = undefined;
    var i: usize = 0;
    while (i < NUM_VECTORS) : (i += 1) {
        const vec = @as(u8, @intCast(i));
        const has_err = hasErrorCode(vec);
        var n = i;
        var tpos: usize = 10;
        while (n > 9) : (n /= 10) {
            tpos -= 1;
            tmp[tpos] = @as(u8, @intCast((n % 10) + '0'));
        }
        tpos -= 1;
        tmp[tpos] = @as(u8, @intCast(n + '0'));
        const suffix = if (has_err) "_err" else "";
        const name = "isrStub" ++ tmp[tpos..10] ++ suffix;
        result[i] = @extern(*const fn () callconv(.naked) void, .{ .name = name });
    }
    break :blk result;
};



pub fn picDisable() void {
    const x86_64 = @import("../x86_64.zig");
    x86_64.outb(0x20, 0x11);
    x86_64.outb(0xA0, 0x11);
    x86_64.outb(0x21, 0x20);
    x86_64.outb(0xA1, 0x28);
    x86_64.outb(0x21, 0x04);
    x86_64.outb(0xA1, 0x02);
    x86_64.outb(0x21, 0x03);
    x86_64.outb(0xA1, 0x03);
    x86_64.outb(0x21, 0xFF);
    x86_64.outb(0xA1, 0xFF);
}

pub fn init(callback: *const fn (*const InterruptFrame) callconv(c_callconv) u64) void {
    common_handler_fn = callback;
    for (0..NUM_VECTORS) |i| {
        const handler_addr = @intFromPtr(stubs[i]);
        idt[i] = IdtEntry{
            .offset_low = @as(u16, @truncate(handler_addr)),
            .selector = 0x08,
            .ist = 0,
            .gate_type = @intFromEnum(GateType.interrupt),
            .dpl = if (i == 3) 3 else 0,
            .present = 1,
            .offset_mid = @as(u16, @truncate(handler_addr >> 16)),
            .offset_high = @as(u32, @truncate(handler_addr >> 32)),
        };
    }
    idtLoad();
    picDisable();
}
