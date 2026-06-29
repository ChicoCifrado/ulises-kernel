pub const KERNEL_OFFSET = 0x0;

pub fn sti() void {
    asm volatile ("msr daifclr, #2");
}

pub fn cli() void {
    asm volatile ("msr daifset, #2");
}

pub fn hlt() void {
    asm volatile ("wfi");
}

pub fn halt() noreturn {
    while (true) {
        cli();
        hlt();
    }
}

pub fn dmb() void {
    asm volatile ("dmb sy");
}

pub fn dsb() void {
    asm volatile ("dsb sy");
}

pub fn isb() void {
    asm volatile ("isb");
}

pub fn readTpidr() u64 {
    return asm ("mrs %[ret], tpidr_el1"
        : [ret] "=r" (-> u64),
    );
}

pub fn writeTpidr(val: u64) void {
    asm volatile ("msr tpidr_el1, %[val]"
        :
        : [val] "r" (val)
    );
}

pub fn readCntpct() u64 {
    asm volatile ("isb");
    return asm ("mrs %[ret], cntpct_el0"
        : [ret] "=r" (-> u64),
    );
}

pub fn readCntfrq() u64 {
    return asm ("mrs %[ret], cntfrq_el0"
        : [ret] "=r" (-> u64),
    );
}

pub fn initCpu() void {
    // Enable FP/SIMD (CPACR_EL1.FPEN = 0b11)
    var tmp: u64 = undefined;
    asm volatile (
        \\mrs %[tmp], cpacr_el1
        \\orr %[tmp], %[tmp], #(3 << 20)
        \\msr cpacr_el1, %[tmp]
        \\isb
        : [tmp] "=&r" (tmp),
    );
    // Check CPU implementer via MIDR_EL1
    const midr = asm ("mrs %[ret], midr_el1"
        : [ret] "=r" (-> u64),
    );
    _ = midr;
}

pub fn virtToPhys(vaddr: anytype) u64 {
    return @intCast(@intFromPtr(vaddr));
}

pub fn serialPutChar(c: u8) void {
    const uart_base = @as([*]volatile u32, @ptrFromInt(0x9000000));
    // Wait for UART not full (PL011 FR[5] = TXFF)
    while ((uart_base[0x18 / 4] & (1 << 5)) != 0) {}
    uart_base[0x00 / 4] = c;
}

pub fn serialCanRead() bool {
    const uart_base = @as([*]volatile u32, @ptrFromInt(0x9000000));
    // PL011 FR[4] = RXFE (receive FIFO empty), bit 6 = RXFF
    return (uart_base[0x18 / 4] & (1 << 4)) == 0;
}

pub fn serialReadChar() u8 {
    const uart_base = @as([*]volatile u32, @ptrFromInt(0x9000000));
    while (uart_base[0x18 / 4] & (1 << 4) != 0) {}
    return @as(u8, @truncate(uart_base[0x00 / 4]));
}

pub fn serialInit() void {
    const uart_base = @as([*]volatile u32, @ptrFromInt(0x9000000));
    // Disable UART
    uart_base[0x30 / 4] = 0;
    dsb();
    // Set baud rate for 115200 (assuming 24MHz UART clock on QEMU virt)
    // IBRD = 24000000 / (16 * 115200) = 13.02 -> 13
    // FBRD = ceil((0.02 * 64) + 0.5) = 1
    uart_base[0x24 / 4] = 13;
    uart_base[0x28 / 4] = 1;
    // Line control: 8n1, FIFO enable
    uart_base[0x2C / 4] = (1 << 4) | (3 << 5); // FEN=1, WLEN=11 (8 bits)
    dsb();
    // Enable UART (TXE=1, RXE=1, UARTEN=1)
    uart_base[0x30 / 4] = (1 << 8) | (1 << 9) | 1;
    dsb();
}

const GICD_BASE = 0x08000000;
const GICC_BASE = 0x08010000;

pub fn gicInit() void {
    const gicd = @as([*]volatile u32, @ptrFromInt(GICD_BASE));
    const gicc = @as([*]volatile u32, @ptrFromInt(GICC_BASE));

    // Set all interrupts to group 1 (non-secure)
    // GICD_IGROUPR at offset 0x080, 1 bit per interrupt, 32 interrupts per register
    const num_irqs = ((gicd[0x004 / 4] & 0x1F) + 1) * 32;
    var i: u32 = 0;
    while (i < num_irqs / 32) : (i += 1) {
        gicd[0x080 / 4 + i] = 0xFFFFFFFF;
    }
    dsb();

    // Enable distributor
    gicd[0x000 / 4] = 1; // GICD_CTLR.Enable = 1
    dsb();

    // Set priority mask to allow all
    gicc[0x004 / 4] = 0xFF; // GICC_PMR
    dsb();

    // Enable CPU interface
    gicc[0x000 / 4] = 1; // GICC_CTLR.Enable = 1
    dsb();
    isb();
}

pub fn gicEnableIrq(irq: u32) void {
    const gicd = @as([*]volatile u32, @ptrFromInt(GICD_BASE));
    const reg = irq / 32;
    const bit = irq % 32;
    gicd[0x100 / 4 + reg] = @as(u32, 1) << @intCast(bit);
    dsb();
}

pub fn gicAck() u32 {
    const gicc = @as([*]volatile u32, @ptrFromInt(GICC_BASE));
    return gicc[0x00C / 4]; // GICC_IAR
}

pub fn gicEoi(irq: u32) void {
    const gicc = @as([*]volatile u32, @ptrFromInt(GICC_BASE));
    gicc[0x010 / 4] = irq; // GICC_EOIR
    dsb();
}

pub fn timerInit(hz: u64) void {
    const freq = readCntfrq();
    if (freq == 0) return;
    const ticks = freq / hz;
    // Set compare value
    const now = readCntpct();
    asm volatile ("msr cntp_cval_el0, %[val]"
        :
        : [val] "r" (now + ticks)
    );
    isb();
    // Enable timer, clear IMASK
    asm volatile ("msr cntp_ctl_el0, %[val]"
        :
        : [val] "r" (@as(u64, 1)) // ENABLE=1, IMASK=0
    );
    isb();
}

pub fn timerHandle() void {
    // Disable timer interrupt
    asm volatile ("msr cntp_ctl_el0, %[val]"
        :
        : [val] "r" (@as(u64, 0))
    );
    isb();
    // Re-arm for next tick
    timerInit(100); // 100 Hz for now
}
