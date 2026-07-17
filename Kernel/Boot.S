// SwiftOS kernel entry point and low-level ARM helpers.
// QEMU virt boots -kernel images at 0x40080000 with x0 = DTB pointer, in EL2 or EL1.

.section .text.boot
.globl _start
_start:
    mov     x20, x0                 // preserve DTB pointer

    mrs     x9, CurrentEL
    lsr     x9, x9, #2
    cmp     x9, #2
    b.ne    1f                      // already at EL1

    // Drop EL2 -> EL1 (EL1 is AArch64, EL1h with interrupts masked)
    mov     x9, #(1 << 31)
    msr     HCR_EL2, x9
    msr     CPTR_EL2, xzr           // don't trap EL1 FP/SIMD access at EL2
    mov     x9, #0x3c5              // SPSR: EL1h, DAIF all masked
    msr     SPSR_EL2, x9
    adr     x9, 1f
    msr     ELR_EL2, x9
    eret

1:
    mov     x9, #(0x3 << 20)        // CPACR_EL1.FPEN: full FP/SIMD access at EL1
    msr     CPACR_EL1, x9
    isb

    ldr     x9, =stack_top
    mov     sp, x9

    // Zero the BSS
    ldr     x9, =__bss_start
    ldr     x10, =__bss_end
2:
    cmp     x9, x10
    b.hs    3f
    str     xzr, [x9], #8
    b       2b
3:
    dsb     sy
    isb

    mov     x0, x20                 // kmain(dtb:)
    bl      kmain

4:                                  // kmain must not return
    wfe
    b       4b

// ---------------------------------------------------------------- helpers ---

.globl arm_read_cntfrq
arm_read_cntfrq:
    mrs     x0, CNTFRQ_EL0
    ret

.globl arm_read_cntpct
arm_read_cntpct:
    mrs     x0, CNTPCT_EL0
    ret

.globl arm_read_current_el
arm_read_current_el:
    mrs     x0, CurrentEL
    lsr     x0, x0, #2
    ret

.globl arm_wfi
arm_wfi:
    wfi
    ret

.globl arm_dsb_sy
arm_dsb_sy:
    dsb     sy
    ret

.globl arm_isb
arm_isb:
    isb
    ret

.globl arm_irq_enable
arm_irq_enable:
    msr     daifclr, #2
    ret

.globl arm_irq_disable
arm_irq_disable:
    msr     daifset, #2
    ret

// ----------------------------------------------------------------- data -----

.data
.globl __stack_chk_guard
__stack_chk_guard:
    .quad   0x595e9f2c3a7b1d0f

.section .bss
.align  4
stack:
    .skip   65536
stack_top:
