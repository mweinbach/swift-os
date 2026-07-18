// Exception vector table, IRQ entry stub, and timer/vector sysreg helpers.
// GICv2 on QEMU virt: GICD at 0x08000000, GICC at 0x08010000.
// The kernel runs at EL1h, so EL1 exceptions use the "current EL, SPx" rows.
// The "lower EL, AArch64" rows serve EL0 user code (Kernel/Userspace.swift):
// SVC syscalls and user faults land in sync_lower_entry, timer IRQs that
// preempt EL0 reuse irq_entry (its frame covers SPSR/ELR, so eret returns
// to EL0 exactly as it returns to an interrupted EL1 thread).
//
// Fatal paths (Kernel/Panic.swift): every fatal exception — synchronous at
// EL1, FIQ, SError, or an architecturally unexpected vector — snapshots ALL
// GPRs plus the exception-time SP into a 256-byte stack frame and calls
//   swift_fatal_exception(kind=x0, esr=x1, elr=x2, far=x3, spsr=x4, frame=x5)
// with frame = [x0...x30] at [sp+0..240] and the exception-time SP at
// [sp+248]. kind: 0 = sync at EL1, 1 = FIQ, 2 = SError, 3 = unexpected
// vector. The ONLY sync exceptions not taking this path come from EL0 and
// are handled by sync_lower_entry -> swift_sync_lower: SVC64 syscalls are
// serviced, and non-SVC user faults kill just the run (the documented user
// crash guard in Kernel/Userspace.swift — deliberate; do NOT "harden" that
// into a kernel panic. A lower-EL sync with no active run still panics via
// kpanic, which is the can't-happen path).

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

// ---- Lower EL, AArch64 (EL0 user code — see header) ------------------------
.balign 128
    b       sync_lower_entry                // synchronous (SVC / user fault)
.balign 128
    b       irq_entry                       // IRQ (preempting EL0)
.balign 128
    b       fiq_entry                       // FIQ (none exist — panics)
.balign 128
    b       serror_entry                    // SError (panics)

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

// Register snapshot for the fatal paths: 256-byte frame on the current
// stack, [sp+0..240] = x0...x30, [sp+248] = the exception-time SP.
// Clobbers x9 (already saved). Passed to swift_fatal_exception as x5 = sp.
.macro PANIC_FRAME
    sub     sp, sp, #256
    stp     x0,  x1,  [sp, #0]
    stp     x2,  x3,  [sp, #16]
    stp     x4,  x5,  [sp, #32]
    stp     x6,  x7,  [sp, #48]
    stp     x8,  x9,  [sp, #64]
    stp     x10, x11, [sp, #80]
    stp     x12, x13, [sp, #96]
    stp     x14, x15, [sp, #112]
    stp     x16, x17, [sp, #128]
    stp     x18, x19, [sp, #144]
    stp     x20, x21, [sp, #160]
    stp     x22, x23, [sp, #176]
    stp     x24, x25, [sp, #192]
    stp     x26, x27, [sp, #208]
    stp     x28, x29, [sp, #224]
    str     x30, [sp, #240]
    add     x9, sp, #256
    str     x9, [sp, #248]                  // SP at exception time
.endm

// Synchronous exception from EL1h: full register snapshot + ESR/ELR/FAR/SPSR
// to Kernel/Panic.swift (via swift_fatal_exception). Never returns.
sync_exception_entry:
    PANIC_FRAME
    mov     x0, #0                          // kind 0 = sync at EL1
    mrs     x1, ESR_EL1
    mrs     x2, ELR_EL1
    mrs     x3, FAR_EL1
    mrs     x4, SPSR_EL1
    mov     x5, sp
    bl      swift_fatal_exception           // Never returns
1:  wfi
    b       1b

// Synchronous exception from EL0 (AArch64): SVC syscalls and user faults.
// Saves a 176-byte frame (x0-x18, x30, SPSR_EL1, ELR_EL1 — layout documented
// at the swift_sync_lower call site in Kernel/Userspace.swift; irq_entry's
// frame below is a different, larger one — the two are NOT shared), then:
//   x0 = ESR_EL1, x1 = frame pointer, bl swift_sync_lower
// Return 0: resume EL0 — write the frame back (the handler may have updated
// the saved x0 return value; ELR already points past the svc on entry, so
// no ELR fixup is needed) and eret.
// Return != 0: the run is over (1 = exit syscall, 2 = user fault). Reload
// the kernel SP that arm_run_el0 stashed in el0_kernel_save and jump into
// its epilogue (el0_exited) with the marker in x0 — from the caller's
// perspective arm_run_el0 simply returns. The abandoned sync frame sits
// above the restored SP and is discarded.
sync_lower_entry:
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

    mrs     x0, ESR_EL1
    mov     x1, sp
    bl      swift_sync_lower
    cbnz    x0, 1f

    // Resume EL0 (or panic-loop below if this was a kernel-side bug).
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

1:  // Teardown: x0 = marker (1 = exit, 2 = fault). Switch back to the
    // stack arm_run_el0 was called on, restore the DAIF it saved (exception
    // entry masked IRQs — without this the caller's thread would keep
    // running with IRQs off and the timer tick would never fire again),
    // and let arm_run_el0 return the marker.
    adr     x9, el0_kernel_save
    ldp     x10, x11, [x9]
    mov     sp, x10
    msr     daif, x11
    b       el0_exited                    // in Kernel/Userspace.S

// IRQ from EL1h. The interrupted context owns every register, so save all
// caller-saved GPRs (x0-x18), x30, AND the AAPCS caller-saved NEON
// registers q0-q7 around the Swift call, then eret. (q8-q15 are
// callee-saved per AAPCS; they ride the scheduler's switch frame in
// Scheduler.S.) Without q0-q7 here, any vector code the IRQ handler emits
// (the compiler can and does, e.g. 16-byte copies) would silently corrupt
// the interrupted context. Frame: 304 bytes —
//   [sp+0..143]   x0-x17 (stp pairs)
//   [sp+144/152]  x18 / x30
//   [sp+160]      SPSR_EL1 / ELR_EL1
//   [sp+176..303] q0-q7 (128-bit stp pairs)
// SPSR_EL1/ELR_EL1 are saved in the frame too: with the preemptive
// scheduler, the handler may context-switch, and the next IRQ (on another
// thread) would otherwise overwrite them — the eventual eret must restore
// THIS thread's exception context, not the latest one.
irq_entry:
    sub     sp, sp, #304
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
    stp     q0,  q1,  [sp, #176]
    stp     q2,  q3,  [sp, #208]
    stp     q4,  q5,  [sp, #240]
    stp     q6,  q7,  [sp, #272]

    movz    x9, #0x0801, lsl #16            // GICC base 0x08010000
    ldr     w0, [x9, #0x0C]                 // GICC_IAR: acknowledge
    and     w10, w0, #0x3FF                 // INTID
    cmp     w10, #1023
    b.eq    1f                              // spurious: no EOIR, just return
    cmp     w10, #1
    b.eq    panic_halt_ipi                  // SGI 1: another core panicked
    bl      swift_irq_dispatch              // x0 = IAR: tick, reprogram, EOIR
1:
    ldp     q0,  q1,  [sp, #176]
    ldp     q2,  q3,  [sp, #208]
    ldp     q4,  q5,  [sp, #240]
    ldp     q6,  q7,  [sp, #272]
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
    add     sp, sp, #304
    eret

// Panic-halt IPI (SGI 1, broadcast by Kernel/Panic.swift): another core is
// panicking and owns the UART + screen from here on. Park THIS core
// immediately and SILENTLY: mask the whole DAIF set and wfi forever. Prints
// NOTHING (the serial line belongs to the panicking core's dump), takes no
// locks, and writes no EOIR — the abandoned IRQ frame and the un-EOI'd SGI
// are irrelevant once the core is parked for good.
panic_halt_ipi:
    msr     daifset, #0xF
1:  wfi
    b       1b

// FIQ: none are configured (the GIC is run in IRQ-only mode), so taking one
// is fatal. FIQ entry sets no ESR/FAR — pass zeroes; ELR/SPSR are real.
fiq_entry:
    PANIC_FRAME
    mov     x0, #1                          // kind 1 = FIQ
    mov     x1, xzr                         // ESR is not meaningful on FIQ
    mrs     x2, ELR_EL1
    mov     x3, xzr                         // FAR is not meaningful on FIQ
    mrs     x4, SPSR_EL1
    mov     x5, sp
    bl      swift_fatal_exception           // Never returns
1:  wfi
    b       1b

// SError (asynchronous external abort): ESR carries the (often imprecise)
// syndrome; ELR is approximate. Always fatal.
serror_entry:
    PANIC_FRAME
    mov     x0, #2                          // kind 2 = SError
    mrs     x1, ESR_EL1
    mrs     x2, ELR_EL1
    mrs     x3, FAR_EL1
    mrs     x4, SPSR_EL1
    mov     x5, sp
    bl      swift_fatal_exception           // Never returns
1:  wfi
    b       1b

// A vector row the kernel should never take (SP0 rows, AArch32 rows).
vector_unexpected:
    PANIC_FRAME
    mov     x0, #3                          // kind 3 = unexpected vector
    mrs     x1, ESR_EL1
    mrs     x2, ELR_EL1
    mrs     x3, FAR_EL1
    mrs     x4, SPSR_EL1
    mov     x5, sp
    bl      swift_fatal_exception           // Never returns
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

// Mask the whole DAIF set (debug, SError, IRQ, FIQ) — panic/halt paths,
// where the timer tick and any nested exception must stop entirely.
// (arm_irq_disable in Boot.S only masks IRQ.)
.globl arm_mask_all
arm_mask_all:
    msr     daifset, #0xF
    ret
