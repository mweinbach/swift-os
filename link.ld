ENTRY(_start)
SECTIONS {
  . = 0x40080000;
  .text : { *(.text.boot) *(.text*) }
  . = ALIGN(16);
  .rodata : { *(.rodata*) }
  . = ALIGN(16);
  .data : { *(.data*) }
  . = ALIGN(16);
  __bss_start = .;
  .bss : { *(.bss*) *(COMMON) }
  . = ALIGN(16);
  __bss_end = .;
  . = ALIGN(4096);
  __end = .;
}
