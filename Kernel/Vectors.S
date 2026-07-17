// Exception vector table, IRQ entry stub, and timer/vector sysreg helpers.
// GICv2 on QEMU virt: GICD at 0x08000000, GICC at 0x08010000.
// The kernel runs at EL1h, so only the "current EL, SPx" rows are used.

.section .text.vectors

// VBAR_EL1 must be 2048-byte aligned: 16 entries of 0x80 bytes each.
.balign 2048
.globl exception_vectors
exception_vectors:

// ---- Current EL, using SP_EL0 (unused: the kernel never runs on SP0) ------
.balign 128
    b       vector_unexpected               // synchronous
.balign 128
    b       vector_unexpected               // IRQ
.balign 128
    b       vector_unexpected               // FIQ
.balign 128
    b       vector_unexpected               // SError

// ---- Current EL, using SP_EL1 (the rows the kernel actually takes) --------
.balign 128
    b       sync_exception_entry            // synchronous
.balign 128
    b       irq_entry                       // IRQ
.balign 128
    b       fiq_entry                       // FIQ
.balign 128
    b       serror_entry                    // SError

// ---- Lower EL, AArch64 (no user processes yet) ----------------------------
.balign 128
    b       vector_unexpected
.balign 128
    b       vector_unexpected
.balign 128
    b       vector_unexpected
.balign 128
    b       vector_unexpected

// ---- Lower EL, AArch32 -----------------------------------------------------
.balign 128
    b       vector_unexpected
.balign 128
    b       vector_unexpected
.balign 128
    b       vector_unexpected
.balign 128
    b       vector_unexpected

// ------------------------------------------------------------ handlers -----

// Synchronous exception from EL1h: hand ESR/ELR to Swift, print + panic.
sync_exception_entry:
    mrs     x0, ESR_EL1
    mrs     x1, ELR_EL1
    bl      swift_sync_exception            // Never returns
1:  wfi
    b       1b

// IRQ from EL1h. The interrupted context owns every register, so save all
// caller-saved GPRs (x0-x18) and x30 around the Swift call, then eret.
// SPSR_EL1/ELR_EL1 are saved in the frame too: with the preemptive
// scheduler, the handler may context-switch, and the next IRQ (on another
// thread) would otherwise overwrite them — the eventual eret must restore
// THIS thread's exception context, not the latest one.
irq_entry:
    sub     sp, sp, #176
    stp     x0,  x1,  [sp, #0]
    stp     x2,  x3,  [sp, #16]
    stp     x4,  x5,  [sp, #32]
    stp     x6,  x7,  [sp, #48]
    stp     x8,  x9,  [sp, #64]
    stp     x10, x11, [sp, #80]
    stp     x12, x13, [sp, #96]
    stp     x14, x15, [sp, #112]
    stp     x16, x17, [sp, #128]
    str     x18, [sp, #144]
    str     x30, [sp, #152]
    mrs     x9, SPSR_EL1
    mrs     x10, ELR_EL1
    stp     x9, x10, [sp, #160]

    movz    x9, #0x0801, lsl #16            // GICC base 0x08010000
    ldr     w0, [x9, #0x0C]                 // GICC_IAR: acknowledge
    and     w10, w0, #0x3FF                 // INTID
    cmp     w10, #1023
    b.eq    1f                              // spurious: no EOIR, just return
    bl      swift_irq_dispatch              // x0 = IAR: tick, reprogram, EOIR
1:
    ldp     x9, x10, [sp, #160]
    msr     SPSR_EL1, x9
    msr     ELR_EL1, x10
    ldp     x0,  x1,  [sp, #0]
    ldp     x2,  x3,  [sp, #16]
    ldp     x4,  x5,  [sp, #32]
    ldp     x6,  x7,  [sp, #48]
    ldp     x8,  x9,  [sp, #64]
    ldp     x10, x11, [sp, #80]
    ldp     x12, x13, [sp, #96]
    ldp     x14, x15, [sp, #112]
    ldp     x16, x17, [sp, #128]
    ldr     x18, [sp, #144]
    ldr     x30, [sp, #152]
    add     sp, sp, #176
    eret

fiq_entry:
    bl      swift_fiq_exception             // Never returns
1:  wfi
    b       1b

serror_entry:
    mrs     x0, ESR_EL1
    mrs     x1, ELR_EL1
    bl      swift_serror_exception          // Never returns
1:  wfi
    b       1b

vector_unexpected:
    bl      swift_unexpected_vector         // Never returns
1:  wfi
    b       1b

// ------------------------------------------------------------- helpers -----

// Install exception_vectors into VBAR_EL1.
.globl arm_install_vectors
arm_install_vectors:
    adr     x0, exception_vectors
    msr     VBAR_EL1, x0
    isb
    ret

// Program the EL1 physical timer down-counter (TimerValue is the low 32 bits).
.globl arm_write_cntp_tval
arm_write_cntp_tval:
    msr     CNTP_TVAL_EL0, x0
    ret

// CNTP_CTL_EL0: bit 0 ENABLE, bit 1 IMASK, bit 2 ISTATUS.
.globl arm_write_cntp_ctl
arm_write_cntp_ctl:
    msr     CNTP_CTL_EL0, x0
    ret
