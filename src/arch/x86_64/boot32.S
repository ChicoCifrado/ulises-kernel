.section .mb2, "a", @progbits
.align 8
multiboot2_header_start:
    .long 0xe85250d6                       // magic
    .long 0                                // architecture: x86 (32-bit protected)
    .long multiboot2_header_end - multiboot2_header_start // header length
    .long 0x100000000 - (0xe85250d6 + 0 + (multiboot2_header_end - multiboot2_header_start)) // checksum
    // Framebuffer request tag (type 5)
    .word 5                                // type
    .word 0                                // flags
    .long 20                               // size
    .long 0                                // width (any)
    .long 0                                // height (any)
    .long 0                                // depth (any)
    .align 8
    // end tag
    .word 0                                // type
    .word 0                                // flags
    .long 8                                // size
multiboot2_header_end:

.section .early.text, "ax"
.code32
.globl _start
.type _start, @function
_start:
    cli
    cld
    // Save multiboot2 info pointer (%ebx) in %esi — will be clobbered later
    movl    %ebx, %esi
    // Build identity page tables (PML4[0] -> PDPT[0] -> PD[0..511] = 2MB pages, 0-1GB)
    leal    pml4, %edi
    xorl    %eax, %eax
    movl    $1024, %ecx
    rep
    stosl
    leal    pdpt, %edi
    movl    $1024, %ecx
    rep
    stosl
    leal    pd, %edi
    movl    $1024, %ecx
    rep
    stosl
    // Fill PD[0..511] with 2MB page entries (identity: 0-1GB)
    leal    pd, %edi
    xorl    %ecx, %ecx
0:
    movl    %ecx, %eax
    shll    $21, %eax
    orl     $0x83, %eax
    movl    %eax, (%edi, %ecx, 8)
    movl    $0, 4(%edi, %ecx, 8)
    incl    %ecx
    cmpl    $512, %ecx
    jb      0b
    // PDPT[0] -> PD
    leal    pd, %eax
    orl     $0x03, %eax
    movl    %eax, pdpt
    movl    $0, pdpt + 4
    // PML4[0] -> PDPT
    leal    pdpt, %eax
    orl     $0x03, %eax
    movl    %eax, pml4
    movl    $0, pml4 + 4
    // Fill pd_mmio[0..511] with 2MB page entries (identity: 3-4GB)
    leal    pd_mmio, %edi
    xorl    %ecx, %ecx
0:
    movl    %ecx, %eax
    shll    $21, %eax
    orl     $0xC0000000, %eax
    orl     $0x83, %eax
    movl    %eax, (%edi, %ecx, 8)
    movl    $0, 4(%edi, %ecx, 8)
    incl    %ecx
    cmpl    $512, %ecx
    jb      0b
    // PDPT[3] -> pd_mmio (covers physical 3-4GB including IOAPIC/LAPIC)
    leal    pd_mmio, %eax
    orl     $0x03, %eax
    movl    %eax, pdpt + 24
    movl    $0, pdpt + 28
    // GDT[0]: null descriptor
    movl    $0, boot_gdt
    movl    $0, boot_gdt + 4
    // GDT[1]: 64-bit code segment (selector 0x08)
    movl    $0, boot_gdt + 8
    movb    $0, boot_gdt + 12
    movb    $0x9A, boot_gdt + 13
    movb    $0xAF, boot_gdt + 14
    movb    $0, boot_gdt + 15
    // GDT[2]: data segment (selector 0x10)
    movl    $0, boot_gdt + 16
    movb    $0, boot_gdt + 20
    movb    $0x92, boot_gdt + 21
    movb    $0xCF, boot_gdt + 22
    movb    $0, boot_gdt + 23
    // GDT descriptor
    movw    $23, boot_gdt_desc
    leal    boot_gdt, %eax
    movl    %eax, boot_gdt_desc + 2
    lgdt    boot_gdt_desc
    // Enable PAE (CR4.PAE = bit 5) + SSE (OSFXSR = bit 9, OSXMMEXCPT = bit 10)
    movl    %cr4, %eax
    orl     $(1 << 5) | (1 << 9) | (1 << 10), %eax
    movl    %eax, %cr4
    // Clear CR0.EM (bit 4) to enable x87 FPU
    movl    %cr0, %ebx
    andl    $~(1 << 4), %ebx
    movl    %ebx, %cr0
    // Load CR3 with PML4 physical address
    leal    pml4, %eax
    movl    %eax, %cr3
    // Enable long mode (IA32_EFER.LME = bit 8 via MSR 0xC0000080)
    movl    $0xC0000080, %ecx
    rdmsr
    orl     $(1 << 8), %eax
    wrmsr
    // Enable paging (CR0.PG = bit 31)
    movl    %cr0, %eax
    orl     $(1 << 31), %eax
    movl    %eax, %cr0
    // Far jump to 64-bit code (selector 0x08 = GDT[1], 64-bit CS)
    .byte 0xEA
    .long entry64
    .word 0x08

.code64
entry64:
    // Reload data segment registers (selector 0x10 = GDT[2])
    movl    $0x10, %eax
    movl    %eax, %ds
    movl    %eax, %es
    movl    %eax, %ss
    // Set up kernel stack
    leaq    kernel_stack(%rip), %rsp
    addq    $32768, %rsp
    // Clear BSS
    movq    $_bss_start, %rdi
    movq    $_bss_end, %rcx
    subq    %rdi, %rcx
    xorl    %eax, %eax
    rep
    stosb
    // Restore multiboot2 info pointer (preserved in %esi from 32-bit entry)
    movq    %rsi, mboot_info(%rip)
    // Call kmain
    xorq    %rbp, %rbp
    movb    $0x4B, %al
    movw    $0xe9, %dx
    outb    %al, %dx
    leaq    kmain(%rip), %rax
    call    *%rax
0:
    cli
    hlt
    jmp     0b
