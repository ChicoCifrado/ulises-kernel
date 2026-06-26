const std = @import("std");
const builtin = @import("builtin");

export var mboot_info: u64 linksection(".early.data") = 0;

export var kernel_stack: [32768]u8 align(16) linksection(".early.data") = undefined;

pub export var pml4: [512]u64 align(4096) linksection(".early.data") = [_]u64{0} ** 512;
export var pdpt: [512]u64 align(4096) linksection(".early.data") = [_]u64{0} ** 512;
export var pd: [512]u64 align(4096) linksection(".early.data") = [_]u64{0} ** 512;
pub export var pd_mmio: [512]u64 align(4096) linksection(".early.data") = [_]u64{0} ** 512;

export var boot_gdt: [24]u8 align(8) linksection(".early.data") = [_]u8{0} ** 24;
export var boot_gdt_desc: [6]u8 linksection(".early.data") = [_]u8{0} ** 6;

comptime {
    asm (
        \\.pushsection .mb2, "a"
        \\.balign 8
        \\mb2_header_start:
        \\.4byte 0xE85250D6
        \\.4byte 0
        \\.4byte mb2_header_end - mb2_header_start
        \\.4byte -(0xE85250D6 + 0 + (mb2_header_end - mb2_header_start))
        \\.2byte 0
        \\.2byte 0
        \\.4byte 8
        \\mb2_header_end:
        \\.popsection
    );
}

export fn _start() linksection(".early.text") callconv(.Naked) noreturn {
    asm volatile (
        \\.code32
        // GRUB Multiboot2 entry: 32-bit protected mode (CR0.PE=1, PG=0).
        // RBX = Multiboot2 info address.
        // Diagnose: write '!' to QEMU debug port 0xe9
        \\    movb    $0x21, %al
        \\    movw    $0xe9, %dx
        \\    outb    %al, %dx
        \\    cli
        \\    cld
        \\    movl    %ebx, mboot_info
        //
        // Build page tables for long mode (PML4 + PDPT + PD with 2MB pages)
        // All tables are in .early.data at physical addresses 0x10xxxx.
        //
        // Zero PML4 (512 * 8 = 4096 bytes)
        \\    leal    pml4, %edi
        \\    xorl    %eax, %eax
        \\    movl    $1024, %ecx
        \\    rep
        \\    stosl
        // Zero PDPT (4096 bytes)
        \\    leal    pdpt, %edi
        \\    movl    $1024, %ecx
        \\    rep
        \\    stosl
        // Zero PD (4096 bytes)
        \\    leal    pd, %edi
        \\    movl    $1024, %ecx
        \\    rep
        \\    stosl
        // Fill PD[0..511] with 2MB page entries (identity: 0-1GB)
        \\    leal    pd, %edi
        \\    xorl    %ecx, %ecx
        \\0:
        \\    movl    %ecx, %eax
        \\    shll    $21, %eax
        \\    orl     $0x83, %eax
        \\    movl    %eax, (%edi, %ecx, 8)     // lower 32 bits
        \\    movl    $0, 4(%edi, %ecx, 8)       // upper 32 bits
        \\    incl    %ecx
        \\    cmpl    $512, %ecx
        \\    jb      0b
        // PDPT[0] -> PD (VA 0 to 1GB identity)
        \\    leal    pd, %eax
        \\    orl     $0x03, %eax
        \\    movl    %eax, pdpt
        \\    movl    $0, pdpt + 4
        // PDPT[510] -> PD (higher-half: VA 0xFFFFFFFF80000000 to +1GB)
        \\    movl    %eax, pdpt + 510*8
        \\    movl    $0, pdpt + 510*8 + 4
        // PML4[0] -> PDPT (VA 0 to 512GB identity)
        \\    leal    pdpt, %eax
        \\    orl     $0x03, %eax
        \\    movl    %eax, pml4
        \\    movl    $0, pml4 + 4
        // PML4[511] -> PDPT (higher-half: VA 0xFFFFFF8000000000 to +512GB)
        // Kernel at 0xFFFFFFFF80000000+ falls in PML4[511] range.
        \\    movl    %eax, pml4 + 511*8
        \\    movl    $0, pml4 + 511*8 + 4
        // Map IOAPIC (0xFEC00000) and LAPIC (0xFEE00000) via PDPT[3] -> pd_mmio
        // Zero pd_mmio (part of .early.data, already zeroed)
        // PDPT[3] -> pd_mmio (physical address)
        \\    leal    pd_mmio, %eax
        \\    orl     $0x03, %eax
        \\    movl    %eax, pdpt + 3*8
        \\    movl    $0, pdpt + 3*8 + 4
        // pd_mmio[502] = 0xFEC00000 | 0x93 (IOAPIC, 2MB UC r/w page)
        \\    movl    $0xFEC00000, pd_mmio + 502*8
        \\    orl     $0x93, pd_mmio + 502*8
        \\    movl    $0, pd_mmio + 502*8 + 4
        // pd_mmio[503] = 0xFEE00000 | 0x93 (LAPIC, 2MB UC r/w page)
        \\    movl    $0xFEE00000, pd_mmio + 503*8
        \\    orl     $0x93, pd_mmio + 503*8
        \\    movl    $0, pd_mmio + 503*8 + 4
        // Set up GDT for long mode transition
        // GDT[0]: null descriptor
        \\    movl    $0, boot_gdt
        \\    movl    $0, boot_gdt + 4
        // GDT[1]: 64-bit code segment (selector 0x08)
        \\    movl    $0, boot_gdt + 8
        \\    movb    $0, boot_gdt + 12
        \\    movb    $0x9A, boot_gdt + 13
        \\    movb    $0xAF, boot_gdt + 14
        \\    movb    $0, boot_gdt + 15
        // GDT[2]: data segment (selector 0x10)
        \\    movl    $0, boot_gdt + 16
        \\    movb    $0, boot_gdt + 20
        \\    movb    $0x92, boot_gdt + 21
        \\    movb    $0xCF, boot_gdt + 22
        \\    movb    $0, boot_gdt + 23
        // GDT descriptor
        \\    movw    $23, boot_gdt_desc
        \\    leal    boot_gdt, %eax
        \\    movl    %eax, boot_gdt_desc + 2
        \\    lgdt    boot_gdt_desc
        // Trace: GDT loaded ('G')
        \\    movb    $0x47, %al
        \\    movw    $0xe9, %dx
        \\    outb    %al, %dx
        // Enable PAE (CR4.PAE = bit 5)
        \\    movl    %cr4, %eax
        \\    orl     $(1 << 5), %eax
        \\    movl    %eax, %cr4
        // Load CR3 with PML4 physical address
        \\    leal    pml4, %eax
        \\    movl    %eax, %cr3
        // Trace: CR3 loaded ('A')
        \\    movb    $0x41, %al
        \\    movw    $0xe9, %dx
        \\    outb    %al, %dx
        // Enable long mode (IA32_EFER.LME = bit 8 via MSR 0xC0000080)
        \\    movl    $0xC0000080, %ecx
        \\    rdmsr
        \\    orl     $(1 << 8), %eax
        \\    wrmsr
        // Enable paging (CR0.PG = bit 31) — transitions to long mode
        \\    movl    %cr0, %eax
        \\    orl     $(1 << 31), %eax
        \\    movl    %eax, %cr0
        // Far jump to 64-bit code (selector 0x08 = GDT[1], 64-bit CS)
        \\.byte 0xEA
        \\.long entry64
        \\.word 0x08
        //
        // ===== 64-bit long mode =====
        //
        \\.code64
        \\entry64:
        // Reload data segment registers (selector 0x10 = GDT[2])
        \\    movl    $0x10, %eax
        \\    movl    %eax, %ds
        \\    movl    %eax, %es
        \\    movl    %eax, %fs
        \\    movl    %eax, %gs
        \\    movl    %eax, %ss
        // Trace: long mode active ('L')
        \\    movb    $0x4C, %al
        \\    movw    $0xe9, %dx
        \\    outb    %al, %dx
        // Set up kernel stack
        \\    leaq    kernel_stack(%rip), %rsp
        \\    addq    $32768, %rsp
        // Trace: stack set up ('S')
        \\    movb    $0x53, %al
        \\    movw    $0xe9, %dx
        \\    outb    %al, %dx
        // Clear BSS
        \\    movq    $_bss_start, %rdi
        \\    movq    $_bss_end, %rcx
        \\    subq    %rdi, %rcx
        \\    xorl    %eax, %eax
        \\    rep
        \\    stosb
        // Trace: BSS cleared, calling kmain ('X')
        \\    movb    $0x58, %al
        \\    movw    $0xe9, %dx
        \\    outb    %al, %dx
        // Call kmain through identity-mapped (physical) address
        \\    xorq    %rbp, %rbp
        // Trace: about to call kmain ('c')
        \\    movb    $0x63, %al
        \\    movw    $0xe9, %dx
        \\    outb    %al, %dx
        // kmain physical = LMA = VMA - 0xFFFFFFFF80000000
        \\    movq    $kmain, %rax
        \\    subq    $0xFFFFFFFF80000000, %rax
        \\    call    *%rax
        // Trace: returned from kmain ('E')
        \\    movb    $0x45, %al
        \\    movw    $0xe9, %dx
        \\    outb    %al, %dx
        \\0:
        \\    cli
        \\    hlt
        \\    jmp     0b
    );
}
