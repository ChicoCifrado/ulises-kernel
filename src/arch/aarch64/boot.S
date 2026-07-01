.section .text._start, "ax"
.globl _start
.type _start, @function
_start:
    // QEMU virt entry: x0 = FDT address
    // Save FDT address for later use
    mov     x19, x0

    // Check current exception level
    mrs     x0, CurrentEL
    and     x0, x0, #0x0C
    lsr     x0, x0, #2
    cmp     x0, #3
    b.eq    el3_entry
    cmp     x0, #2
    b.eq    el2_entry
    cmp     x0, #1
    b.eq    el1_entry
    b       hang

// Debug: write a character to UART (blocking, physical address)
.macro dbg_chr ch
    ldr     x1, =0x9000000
    ldr     x2, =0x9000018
1:  ldr     w3, [x2]
    tbnz    w3, #5, 1b
    mov     w3, #(\ch)
    str     w3, [x1]
.endm

el3_entry:
    // Drop from EL3 to EL2
    mov     x0, #0
    orr     x0, x0, #1
    orr     x0, x0, #(1 << 10)
    orr     x0, x0, #(1 << 1)
    msr     scr_el3, x0
    ldr     x0, =0x3C9
    msr     spsr_el3, x0
    adr     x0, el2_entry
    msr     elr_el3, x0
    eret

el2_entry:
    // Drop from EL2 to EL1
    // Don't touch SCTLR_EL1 — keep hardware reset value

    ldr     x0, =0x0000000080000000
    msr     hcr_el2, x0

    ldr     x0, =0x3C5
    msr     spsr_el2, x0

    adr     x0, el1_entry
    msr     elr_el2, x0
    eret

el1_entry:
    dbg_chr '1'
    adr     x0, exception_vectors
    msr     vbar_el1, x0

    ldr     x0, =_stack_end
    mov     sp, x0

    dbg_chr '2'
    // Ensure MMU registers are clean — QEMU 10.2.1 has bugs with stale page table walks
    msr     tcr_el1, xzr
    msr     ttbr0_el1, xzr
    msr     ttbr1_el1, xzr
    msr     mair_el1, xzr
    isb
    tlbi    vmalle1is
    dsb     sy
    isb

    bl      build_page_tables

    dbg_chr '3'
    // Set page tables and check
    // TCR: T0SZ=25 (39-bit VA), TG0=4KB, IRGN0=WBWA, ORGN0=WBWA, SH0=IS, IPS=32-bit
    ldr     x0, =0x200000F59
    msr     tcr_el1, x0
    isb

    // MAIR: AttrIndx 0 = Normal WBWA (0xFF), 1 = Device (0x00)
    ldr     x0, =0x00FF
    msr     mair_el1, x0

    ldr     x0, =page_table_l0
    msr     ttbr0_el1, x0
    isb

    dbg_chr '4'
    // Enable MMU
    dsb     sy
    isb
    mrs     x0, sctlr_el1
    orr     x0, x0, #1
    msr     sctlr_el1, x0
    isb

    dbg_chr '5'

    // Clear BSS
    ldr     x0, =_bss_start
    ldr     x1, =_bss_end
    sub     x1, x1, x0
    mov     x2, #0
1:  cbz     x1, 2f
    str     xzr, [x0], #8
    sub     x1, x1, #8
    b       1b
2:

    dbg_chr '7'
    mov     x0, x19
    ldr     x1, =kmain
    blr     x1

hang:
    wfi
    b       hang

.section .data.page_tables, "aw"
.align 12
page_table_l0:
    .space 4096, 0
page_table_l1_lo:
    .space 4096, 0
page_table_l1_hi:
    .space 4096, 0
_page_tables_end:

// ===== Exception Vectors =====
.section .text.exception_vectors, "ax"
.align 11
exception_vectors:
    // --- Current EL with SP0 ---
    b       exc_sync_el1
    .align 7
    b       exc_irq_el1
    .align 7
    b       exc_fiq_el1
    .align 7
    b       exc_serror_el1
    .align 7
    // --- Current EL with SPx ---
    b       exc_sync_el1h
    .align 7
    b       exc_irq_el1h
    .align 7
    b       exc_fiq_el1h
    .align 7
    b       exc_serror_el1h
    .align 7
    // --- Lower EL AArch64 ---
    b       exc_sync_el0
    .align 7
    b       exc_irq_el0
    .align 7
    b       exc_fiq_el0
    .align 7
    b       exc_serror_el0
    .align 7
    // --- Lower EL AArch32 ---
    b       exc_sync_el032
    .align 7
    b       exc_irq_el032
    .align 7
    b       exc_fiq_el032
    .align 7
    b       exc_serror_el032
    .align 7

.macro exc_dump label, vnum
\label\():
    stp     x0, x1, [sp, #-16]!
    stp     x2, x3, [sp, #-16]!
    mrs     x0, esr_el1
    mrs     x1, elr_el1
    stp     x0, x1, [sp, #-16]!
    ldr     x2, =0x9000000
    ldr     x3, =0x9000018
1:  ldr     w4, [x3]
    tbnz    w4, #5, 1b
    mov     w4, #'E'
    str     w4, [x2]
2:  ldr     w4, [x3]
    tbnz    w4, #5, 2b
    mov     w4, #(\vnum)
    add     w4, w4, #'0'
    cmp     w4, #'9'
    b.ls    3f
    add     w4, w4, #('A' - '9' - 1)
3:  str     w4, [x2]
4:  ldr     w4, [x3]
    tbnz    w4, #5, 4b
    mov     w4, #' '
    str     w4, [x2]
    ldp     x4, x5, [sp]
    mov     x6, #8
5:  lsr     w7, w4, #28
    and     w7, w7, #0xF
    add     w7, w7, #'0'
    cmp     w7, #'9'
    b.ls    6f
    add     w7, w7, #('A' - '9' - 1)
6:
7:  ldr     w8, [x3]
    tbnz    w8, #5, 7b
    str     w7, [x2]
    lsl     x4, x4, #4
    subs    x6, x6, #1
    b.ne    5b
8:  ldr     w4, [x3]
    tbnz    w4, #5, 8b
    mov     w4, #' '
    str     w4, [x2]
    // Dump FAR_EL1
    mrs     x4, far_el1
    mov     x6, #8
11: lsr     w7, w4, #28
    and     w7, w7, #0xF
    add     w7, w7, #'0'
    cmp     w7, #'9'
    b.ls    12f
    add     w7, w7, #('A' - '9' - 1)
12: ldr     w8, [x3]
    tbnz    w8, #5, 12b
    str     w7, [x2]
    lsl     x4, x4, #4
    subs    x6, x6, #1
    b.ne    11b
13: ldr     w4, [x3]
    tbnz    w4, #5, 13b
    mov     w4, #' '
    str     w4, [x2]
    // Dump ELR_EL1 (from stack, x5)
    mov     x4, x5
    mov     x6, #8
14: lsr     w7, w4, #28
    and     w7, w7, #0xF
    add     w7, w7, #'0'
    cmp     w7, #'9'
    b.ls    15f
    add     w7, w7, #('A' - '9' - 1)
15: ldr     w8, [x3]
    tbnz    w8, #5, 15b
    str     w7, [x2]
    lsl     x4, x4, #4
    subs    x6, x6, #1
    b.ne    14b
16: ldr     w4, [x3]
    tbnz    w4, #5, 16b
    mov     w4, #'\n'
    str     w4, [x2]
    ldp     x0, x1, [sp], #16
    ldp     x2, x3, [sp], #16
    ldp     x0, x1, [sp], #16
10: wfi
    b       10b
.endm

.macro exc_irq label
\label\():
    // Save caller-saved registers (x0-x18) and LR (x30)
    stp     x0, x1, [sp, #-16]!
    stp     x2, x3, [sp, #-16]!
    stp     x4, x5, [sp, #-16]!
    stp     x6, x7, [sp, #-16]!
    stp     x8, x9, [sp, #-16]!
    stp     x10, x11, [sp, #-16]!
    stp     x12, x13, [sp, #-16]!
    stp     x14, x15, [sp, #-16]!
    stp     x16, x17, [sp, #-16]!
    stp     x18, x30, [sp, #-16]!

    // Read GIC IAR (GICC_IAR at 0x0801000C)
    ldr     x0, =0x0801000C
    ldr     w1, [x0]             // w1 = irq number

    // Call Zig handler (pass irq in w0)
    mov     w0, w1
    bl      aarch64_irq_handler

    // Write GIC EOI (GICC_EOIR at 0x08010010)
    ldr     x0, =0x08010010
    str     w1, [x0]

    // Restore and return
    ldp     x18, x30, [sp], #16
    ldp     x16, x17, [sp], #16
    ldp     x14, x15, [sp], #16
    ldp     x12, x13, [sp], #16
    ldp     x10, x11, [sp], #16
    ldp     x8, x9, [sp], #16
    ldp     x6, x7, [sp], #16
    ldp     x4, x5, [sp], #16
    ldp     x2, x3, [sp], #16
    ldp     x0, x1, [sp], #16
    eret
.endm

.macro exc_fiql label
\label\():
    wfi
    b       . - 4
.endm

    exc_dump   exc_sync_el1,   0
    exc_irq    exc_irq_el1
    exc_fiql   exc_fiq_el1
    exc_dump   exc_serror_el1, 3
    exc_dump   exc_sync_el1h,  4
    exc_irq    exc_irq_el1h
    exc_fiql   exc_fiq_el1h
    exc_dump   exc_serror_el1h,7
    exc_dump   exc_sync_el0,   8
    exc_irq    exc_irq_el0
    exc_fiql   exc_fiq_el0
    exc_dump   exc_serror_el0, 11
    exc_dump   exc_sync_el032, 12
    exc_irq    exc_irq_el032
    exc_fiql   exc_fiq_el032
    exc_dump   exc_serror_el032,15
.text

.section .text
build_page_tables:
    // 3-level page tables with 2MB blocks at L1, 4KB pages
    // Two L1 tables: L1_lo for L0[0] (VA 0-1GB), L1_hi for L0[1] (VA 1GB-2GB)
    // Step 1: Zero page table memory
    ldr     x0, =page_table_l0
    ldr     x1, =_page_tables_end
    sub     x1, x1, x0
    mov     x2, #0
1:  cbz     x1, 2f
    str     xzr, [x0], #8
    sub     x1, x1, #8
    b       1b
2:
    // Set MAIR: Attr0=Normal WBWA(0xFF), Attr1=Device-nGnRnE(0x00)
    ldr     x0, =0x00FF
    msr     mair_el1, x0
    isb

    // L0[0] = page_table_l1_lo | 3 (table desc)
    ldr     x0, =page_table_l1_lo
    orr     x0, x0, #0x3
    ldr     x1, =page_table_l0
    str     x0, [x1]

    // L0[1] = page_table_l1_hi | 3 (table desc)
    ldr     x0, =page_table_l1_hi
    orr     x0, x0, #0x3
    str     x0, [x1, #8]

    // Fill L1_lo: 512 entries, each a 2MB block mapping VA 0-1GB identically
    // Attr: AF=1, AP=EL1 RW, SH=NS, AttrIndx=1(Device), block
    ldr     x0, =page_table_l1_lo
    mov     x1, #0              // PA base
    mov     x2, #512            // counter
3:  movz    x3, #0x405          // Device block attrs
    orr     x3, x3, x1          // combine with PA
    str     x3, [x0], #8        // L1[i] = desc
    add     x1, x1, #0x200000   // next 2MB
    subs    x2, x2, #1
    b.ne    3b

    // Fill L1_hi: 512 entries, each a 2MB block mapping VA 1GB-2GB identically
    // Attr: AF=1, AP=EL1 RW, SH=IS, AttrIndx=0(Normal), block
    ldr     x0, =page_table_l1_hi
    mov     x1, #0x40000000     // PA base at 1GB
    mov     x2, #512
4:  movz    x3, #0x701          // Normal block attrs
    orr     x3, x3, x1          // combine with PA  
    str     x3, [x0], #8        // L1[i] = desc
    add     x1, x1, #0x200000   // next 2MB
    subs    x2, x2, #1
    b.ne    4b

    // Flush to memory
    dsb     sy
    isb
    ldr     x0, =page_table_l0
    ldr     x1, =_page_tables_end
5:  dc      cvac, x0
    add     x0, x0, #64
    cmp     x0, x1
    b.lo    5b
    dsb     sy
    isb

    ret

.section .bss
// ===== Stack (zeroed by BSS clear) =====
.align 4
_stack_start:
    .space 65536, 0
_stack_end:
