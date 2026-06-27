.section .text
.global pciConfigReadC
.type pciConfigReadC, @function
pciConfigReadC:
    movzbl %dil, %eax
    shl $16, %eax
    movzbl %sil, %r10d
    shl $11, %r10d
    or %r10d, %eax
    movzbl %dl, %r10d
    shl $8, %r10d
    or %r10d, %eax
    movzbl %cl, %r10d
    and $0xFC, %r10d
    or %r10d, %eax
    or $0x80000000, %eax
    mov $0xCF8, %edx
    outl %eax, %dx
    mov $0xCFC, %edx
    inl %dx, %eax
    ret
