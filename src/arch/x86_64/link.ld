OUTPUT_FORMAT(elf64-x86-64)
ENTRY(_start)

phys = 0x100000;

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

    .text : ALIGN(4K)
    {
        _text_start = .;
        *(.text*)
        *(.text.*)
        _text_end = .;
    } :text

    .rodata : ALIGN(4K)
    {
        _rodata_start = .;
        *(.rodata*)
        *(.rodata.*)
        _rodata_end = .;
    } :rodata

    .data : ALIGN(4K)
    {
        _data_start = .;
        *(.data*)
        *(.data.*)
        _data_end = .;
    } :data

    .bss : ALIGN(4K)
    {
        _bss_start = .;
        *(COMMON)
        *(.bss*)
        *(.bss.*)
        _bss_end = .;
    } :data

    _kernel_phys_end = .;

    /DISCARD/ :
    {
        *(.comment*)
        *(.note.gnu*)
        *(.eh_frame*)
        *(.got*)
        *(.plt*)
    }
}
