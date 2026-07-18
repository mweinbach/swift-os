ENTRY(_start)
SECTIONS {
  /* 0x4020_0000: QEMU ROM-loads its generated FDT (always padded to 1 MiB)
   * at the RAM base 0x4000_0000 only when it fits below the kernel image
   * (hw/arm/boot.c arm_load_dtb, dtb_limit = image low address). The old
   * 0x4008_0000 left 512 KiB and the 1 MiB FDT was silently never loaded;
   * 2 MiB leaves comfortable room. See Kernel/DTB.swift. */
  . = 0x40200000;
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
