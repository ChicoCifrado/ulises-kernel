OUTPUT_FORMAT(elf64-x86-64)
ENTRY(_start)

phys = 0x100000;
higher_half = 0xFFFFFFFF80000000;

PHDRS
{
    early PT_LOAD FLAGS(7);
    text PT_LOAD FLAGS(5);
    rodata PT_LOAD FLAGS(4);
    data PT_LOAD FLAGS(6);
}

SECTIONS
{
    . = phys;

    _kernel_phys_start = .;

    .early : ALIGN(4K)
    {
        KEEP(*(.mb2))
        *(.early.text*)
        *(.early.data*)
    } :early

    _early_end = .;

    . += higher_half;

    .text : AT(ADDR(.text) - higher_half) ALIGN(4K)
    {
        _text_start = .;
        *(.text*)
        *(.text.*)
        _text_end = .;
    } :text

    .rodata : AT(ADDR(.rodata) - higher_half) ALIGN(4K)
    {
        _rodata_start = .;
        *(.rodata*)
        *(.rodata.*)
        _rodata_end = .;
    } :rodata

    .data : AT(ADDR(.data) - higher_half) ALIGN(4K)
    {
        _data_start = .;
        *(.data*)
        *(.data.*)
        _data_end = .;
    } :data

    .bss : AT(ADDR(.bss) - higher_half) ALIGN(4K)
    {
        _bss_start = .;
        *(COMMON)
        *(.bss*)
        *(.bss.*)
        _bss_end = .;
    } :data

    _kernel_phys_end = . - higher_half;

    /DISCARD/ :
    {
        *(.comment*)
        *(.note*)
        *(.eh_frame*)
        *(.got*)
        *(.plt*)
    }
}
