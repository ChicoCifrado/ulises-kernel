const std = @import("std");
const builtin = @import("builtin");

export var mboot_info: u64 linksection(".early.data") = 0;

export var early_stack: [16384]u8 align(16) linksection(".early.data") = undefined;
export var kernel_stack: [32768]u8 align(16) linksection(".early.data") = undefined;

export var pml4: [512]u64 align(4096) linksection(".early.data") = [_]u64{0} ** 512;
export var pdpt: [512]u64 align(4096) linksection(".early.data") = [_]u64{0} ** 512;
export var pd: [512]u64 align(4096) linksection(".early.data") = [_]u64{0} ** 512;

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
        //
        // Multiboot2 entry (32-bit protected mode), %ebx = multiboot2 info
        //
        \\    movl    %ebx, (mboot_info)
        \\    cli
        \\    cld
        //
        // Set up early stack (low address, identity mapped)
        //
        \\    movl    $early_stack, %esp
        \\    addl    $16384, %esp
        //
        // ---- Build page tables ----
        //
        // Clear PML4 (4096 bytes = 1024 dwords)
        //
        \\    movl    $pml4, %edi
        \\    movl    $1024, %ecx
        \\    xorl    %eax, %eax
        \\    rep
        \\    stosl
        //
        // Clear PDPT
        //
        \\    movl    $pdpt, %edi
        \\    movl    $1024, %ecx
        \\    xorl    %eax, %eax
        \\    rep
        \\    stosl
        //
        // Clear PD
        //
        \\    movl    $pd, %edi
        \\    movl    $1024, %ecx
        \\    xorl    %eax, %eax
        \\    rep
        \\    stosl
        //
        // Fill PD: 512 2MB pages covering the first 1GB
        // Each entry: (i << 21) | 0x83 (present|writable|huge)
        //
        \\    movl    $pd, %edi
        \\    xorl    %ecx, %ecx
        \\0:
        \\    movl    %ecx, %eax
        \\    shll    $21, %eax
        \\    orl     $0x83, %eax
        \\    movl    %eax, (%edi,%ecx,8)
        \\    movl    $0, 4(%edi,%ecx,8)
        \\    incl    %ecx
        \\    cmpl    $512, %ecx
        \\    jb      0b
        //
        // PDPT[0] -> PD  (identity-map first 1GB)
        //
        \\    movl    $pd, %eax
        \\    orl     $0x03, %eax
        \\    movl    %eax, (pdpt)
        //
        // PML4[0] -> PDPT  (identity map)
        //
        \\    movl    $pdpt, %eax
        \\    orl     $0x03, %eax
        \\    movl    %eax, (pml4)
        //
        // PML4[256] -> PDPT  (higher-half: 0xFFFFFFFF80000000)
        //
        \\    movl    $pdpt, %eax
        \\    orl     $0x03, %eax
        \\    movl    %eax, (pml4 + 256*8)
        //
        // ---- Set up GDT ----
        //
        // Null descriptor (offset 0, 8 bytes)
        //
        \\    movl    $0, (boot_gdt)
        \\    movl    $0, (boot_gdt + 4)
        //
        // 64-bit code segment (offset 8)
        // Type=0xA (code, exec/read), S=1, DPL=0, P=1
        // L=1, D=0, G=1, Limit[19:16]=0xF
        //
        \\    movl    $0x0000FFFF, (boot_gdt + 8)
        \\    movb    $0x9A, (boot_gdt + 12)
        \\    movb    $0xAF, (boot_gdt + 13)
        \\    movb    $0x00, (boot_gdt + 14)
        \\    movb    $0x00, (boot_gdt + 15)
        //
        // 64-bit data segment (offset 16)
        // Type=0x2 (data, read/write), S=1, DPL=0, P=1
        // L=0, D=0, G=1, Limit[19:16]=0xF
        //
        \\    movl    $0x0000FFFF, (boot_gdt + 16)
        \\    movb    $0x92, (boot_gdt + 20)
        \\    movb    $0xAF, (boot_gdt + 21)
        \\    movb    $0x00, (boot_gdt + 22)
        \\    movb    $0x00, (boot_gdt + 23)
        //
        // GDT descriptor (6 bytes)
        //
        \\    movw    $23, (boot_gdt_desc)
        \\    movl    $boot_gdt, %eax
        \\    movl    %eax, (boot_gdt_desc + 2)
        //
        // ---- Transition to 64-bit long mode ----
        //
        // Enable PAE (CR4.PAE = bit 5)
        //
        \\    movl    %cr4, %eax
        \\    orl     $0x20, %eax
        \\    movl    %eax, %cr4
        //
        // Load CR3 = physical address of PML4
        //
        \\    movl    $pml4, %eax
        \\    movl    %eax, %cr3
        //
        // Enable long mode (EFER.LME = MSR 0xC0000080, bit 8)
        //
        \\    movl    $0xC0000080, %ecx
        \\    rdmsr
        \\    orl     $0x100, %eax
        \\    wrmsr
        //
        // Enable paging (CR0.PG = bit 31)
        //
        \\    movl    %cr0, %eax
        \\    orl     $0x80000000, %eax
        \\    movl    %eax, %cr0
        //
        // Load GDT and far jump to 64-bit code
        // We are now in 32-bit compatibility mode with paging enabled.
        // The far jump with 64-bit CS selector transitions to long mode.
        //
        \\    lgdt    (boot_gdt_desc)
        \\    .byte   0xEA
        \\    .long   _start64
        \\    .word   0x08
        //
        // ---- 64-bit long mode ----
        //
        \\.code64
        \\_start64:
        \\    movw    $0x10, %ax
        \\    movw    %ax, %ds
        \\    movw    %ax, %es
        \\    movw    %ax, %fs
        \\    movw    %ax, %gs
        \\    movw    %ax, %ss
        //
        // Set up kernel stack (still low address, identity mapped)
        //
        \\    leaq    (kernel_stack + 32768)(%rip), %rsp
        //
        // Clear BSS (symbols defined by linker script)
        //
        \\    movq    $_bss_start, %rdi
        \\    movq    $_bss_end, %rcx
        \\    subq    %rdi, %rcx
        \\    xorl    %eax, %eax
        \\    cld
        \\    rep
        \\    stosb
        //
        // Call kmain (higher-half kernel entry)
        //
        \\    xorq    %rbp, %rbp
        \\    movq    $kmain, %rax
        \\    call    *%rax
        //
        // Halt if kernel returns
        //
        \\0:
        \\    cli
        \\    hlt
        \\    jmp     0b
    );
}
