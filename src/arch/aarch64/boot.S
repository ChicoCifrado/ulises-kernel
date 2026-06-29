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
// Clobbers x1, x2, x3
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
    // Set SCR_EL3: NS=1, RW=1 (AArch64 at EL2), HCE=1
    mov     x0, #0
    orr     x0, x0, #1      // NS (Non-Secure)
    orr     x0, x0, #(1 << 10) // RW (AArch64 at lower ELs)
    orr     x0, x0, #(1 << 1) // HCE (Hypervisor Call Enable)
    msr     scr_el3, x0
    // Set SPSR_EL3: EL2h, all exceptions masked
    ldr     x0, =0x3C9
    msr     spsr_el3, x0
    // Return to el2_entry
    adr     x0, el2_entry
    msr     elr_el3, x0
    eret

el2_entry:
    // Drop from EL2 to EL1
    // Set SCTLR_EL1 to known state
    ldr     x0, =0x30C50838
    msr     sctlr_el1, x0

    // Set HCR_EL2 to allow EL1 to use all features
    ldr     x0, =0x0000000080000000
    msr     hcr_el2, x0

    // Set SPSR_EL2 for EL1t (AArch64, all exceptions masked)
    ldr     x0, =0x3C5
    msr     spsr_el2, x0

    // Set ELR_EL2 to return to el1_entry
    adr     x0, el1_entry
    msr     elr_el2, x0

    // Return to EL1
    eret

el1_entry:
    dbg_chr '1'
    // Set up exception vector table (temporary identity-mapped)
    adr     x0, exception_vectors
    msr     vbar_el1, x0

    // Set up stack pointer (SP_EL1)
    ldr     x0, =_stack_end
    mov     sp, x0

    dbg_chr '2'
    // Build identity page tables
    bl      build_page_tables

    dbg_chr '3'

    // Set MAIR (Memory Attribute Indirection Register)
    // Attr0: 0xFF = Normal Memory, Outer/Inner Write-Back Read-Write Allocate
    ldr     x0, =0xFF
    msr     mair_el1, x0

    // Set TCR_EL1 for 4KB pages, 48-bit VA, 48-bit PA
    // T0SZ=25 (512GB), TG0=4KB, SH0=IS, ORGN0=IRGN0=WBWA, PS=48-bit
    ldr     x0, =0x53439
    msr     tcr_el1, x0
    isb

    // Set TTBR0_EL1 to Level 0 table
    ldr     x0, =page_table_l0
    msr     ttbr0_el1, x0
    isb

    dbg_chr '4'
    // Enable MMU with minimal flags: M=1, SA=1, CP15BEN=1
    // Caches disabled (C=0, I=0)
    ldr     x0, =0x30C50039
    msr     sctlr_el1, x0
    isb

    dbg_chr '5'
    // Now running with MMU enabled, identity mapped

    // Reload stack pointer (might be needed after MMU)
    ldr     x0, =_stack_end
    mov     sp, x0

    dbg_chr '6'
    // Clear BSS
    ldr     x0, =_bss_start
    ldr     x1, =_bss_end
    sub     x1, x1, x0
    mov     x2, #0
1:
    cbz     x1, 2f
    str     xzr, [x0], #8
    sub     x1, x1, #8
    b       1b
2:

    dbg_chr '7'
    // Call kmain
    mov     x0, x19            // pass FDT address in x0
    ldr     x1, =kmain
    blr     x1

hang:
    wfi
    b       hang

.section .text
build_page_tables:
    // Identity map 0-4GB using 2MB blocks
    // L0[0] -> L1 table
    // L1[0..3] -> L2 tables (each covering 1GB)
    // Each L2[i] = i*2MB | 0xC03 (AF+AttrIndx0+NS+AP+SH+valid)

    // Zero all page table memory
    ldr     x0, =page_table_l0
    ldr     x1, =_page_tables_end
    sub     x1, x1, x0
    mov     x2, #0
1:
    cbz     x1, 2f
    str     xzr, [x0], #8
    sub     x1, x1, #8
    b       1b
2:

    // L0[0] = phys(page_table_l1) | 0x3 (valid, table)
    ldr     x0, =page_table_l1
    orr     x0, x0, #0x3
    ldr     x1, =page_table_l0
    str     x0, [x1]

    // Set up L1[0] -> L2_0 and L1[1] -> L2_1, etc.
    ldr     x2, =page_table_l2_0
    ldr     x3, =page_table_l1
    mov     x4, #0

1:
    // L1[i] = phys(L2_i) | 0x3
    orr     x0, x2, #0x3
    str     x0, [x3, x4, lsl #3]

    // Fill L2_i with 512 block entries
    mov     x5, #0
    mov     x6, x4
    lsl     x6, x6, #30     // base address for this L2 table (i * 1GB)
2:
    // entry = base + (j << 21) | 0xC03
    orr     x0, x6, x5, lsl #21
    // Valid block: AF=1, SH=3 (Inner Shareable), AttrIndx=0 (Normal WB)
    orr     x0, x6, x5, lsl #21
    movz    x7, #0x703
    orr     x0, x0, x7

    // Store to L2_i[j]
    str     x0, [x2, x5, lsl #3]

    add     x5, x5, #1
    cmp     x5, #512
    b.lo    2b

    // Next L1 entry
    add     x4, x4, #1
    cmp     x4, #4
    b.hs    3f

    // Move to next L2 table
    add     x2, x2, #4096
    b       1b

3:
    ret

// ===== Exception Vectors =====
.section .text.exception_vectors, "ax"
.align 11
exception_vectors:
    // --- Current EL with SP0 ---
    // Sync
    b       exc_sync_el1
    .align 7
    // IRQ
    b       exc_irq_el1
    .align 7
    // FIQ
    b       exc_fiq_el1
    .align 7
    // SError
    b       exc_serror_el1
    .align 7
    // --- Current EL with SPx ---
    // Sync
    b       exc_sync_el1h
    .align 7
    // IRQ
    b       exc_irq_el1h
    .align 7
    // FIQ
    b       exc_fiq_el1h
    .align 7
    // SError
    b       exc_serror_el1h
    .align 7
    // --- Lower EL using AArch64 ---
    // Sync
    b       exc_sync_el0
    .align 7
    // IRQ
    b       exc_irq_el0
    .align 7
    // FIQ
    b       exc_fiq_el0
    .align 7
    // SError
    b       exc_serror_el0
    .align 7
    // --- Lower EL using AArch32 ---
    // Sync
    b       exc_sync_el032
    .align 7
    // IRQ
    b       exc_irq_el032
    .align 7
    // FIQ
    b       exc_fiq_el032
    .align 7
    // SError
    b       exc_serror_el032
    .align 7

// Dump exception info and halt
// x0 = exception class (bits[31:26] of ESR)
.macro exc_dump label, vnum
\label\():
    stp     x0, x1, [sp, #-16]!
    stp     x2, x3, [sp, #-16]!
    mrs     x0, esr_el1
    mrs     x1, elr_el1
    stp     x0, x1, [sp, #-16]!
    // Write "EXC:n ESR=xxxxxxxx ELR=xxxxxxxx\n" to UART
    ldr     x2, =0x9000000       // UART DR
    ldr     x3, =0x9000018       // UART FR
    // Wait for TX ready
1:  ldr     w4, [x3]
    tbnz    w4, #5, 1b
    // 'E'
    mov     w4, #'E'
    str     w4, [x2]
2:  ldr     w4, [x3]
    tbnz    w4, #5, 2b
    // vector number as hex digit
    mov     w4, #(\vnum)
    add     w4, w4, #'0'
    cmp     w4, #'9'
    b.ls    3f
    add     w4, w4, #('A' - '9' - 1)
3:  str     w4, [x2]
    // space
4:  ldr     w4, [x3]
    tbnz    w4, #5, 4b
    mov     w4, #' '
    str     w4, [x2]
    // ESR nybbles
    ldp     x4, x5, [sp]         // x4=ESR, x5=ELR
    mov     x6, #8
5:  lsr     w7, w4, #28
    and     w7, w7, #0xF
    add     w7, w7, #'0'
    cmp     w7, #'9'
    b.ls    6f
    add     w7, w7, #('A' - '9' - 1)
6:  // wait and write
7:  ldr     w8, [x3]
    tbnz    w8, #5, 7b
    str     w7, [x2]
    lsl     x4, x4, #4
    subs    x6, x6, #1
    b.ne    5b
    // space
8:  ldr     w4, [x3]
    tbnz    w4, #5, 8b
    mov     w4, #' '
    str     w4, [x2]
    // newline
9:  ldr     w4, [x3]
    tbnz    w4, #5, 9b
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
    stp     x0, x1, [sp, #-16]!
    // TODO: actual interrupt handling
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

// ===== Page Tables =====
.align 12
page_table_l0:
    .space 4096, 0
page_table_l1:
    .space 4096, 0
page_table_l2_0:
    .space 4096, 0
page_table_l2_1:
    .space 4096, 0
page_table_l2_2:
    .space 4096, 0
page_table_l2_3:
    .space 4096, 0
_page_tables_end:

// ===== Stack =====
.align 4
_stack_start:
    .space 32768, 0
_stack_end:
