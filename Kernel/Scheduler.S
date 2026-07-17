// Preemptive scheduler support: context switch, fresh-thread trampoline,
// and nesting-safe IRQ save/restore helpers.
//
// Switch frame layout (224 bytes, built by pushes below and mirrored by
// Scheduler.spawn when it fabricates a fresh thread's initial frame):
//   [sp +   0]  q14/q15          (pushed last, popped first)
//   [sp +  32]  q12/q13
//   [sp +  64]  q10/q11
//   [sp +  96]  q8/q9
//   [sp + 128]  x29 (fp) / x30 (lr)   <- fresh threads: fp=0, lr=thread_start
//   [sp + 144]  x27/x28
//   [sp + 160]  x25/x26
//   [sp + 176]  x23/x24
//   [sp + 192]  x21/x22
//   [sp + 208]  x19/x20
// If you change this frame, update switchFrameSize / the x30 slot offset in
// Kernel/Scheduler.swift to match.

// void arm_switch_context(UInt *saveSP, UInt newSP)
// Saves the callee-saved GPRs x19-x30 and callee-saved NEON q8-q15 on the
// current stack, stores the resulting SP to *saveSP, switches to newSP,
// pops the same frame and returns — into the new thread's context (or into
// thread_start for a thread that has never run).
.globl arm_switch_context
arm_switch_context:
    stp     x19, x20, [sp, #-16]!
    stp     x21, x22, [sp, #-16]!
    stp     x23, x24, [sp, #-16]!
    stp     x25, x26, [sp, #-16]!
    stp     x27, x28, [sp, #-16]!
    stp     x29, x30, [sp, #-16]!
    stp     q8,  q9,  [sp, #-32]!
    stp     q10, q11, [sp, #-32]!
    stp     q12, q13, [sp, #-32]!
    stp     q14, q15, [sp, #-32]!
    mov     x9, sp
    str     x9, [x0]
    mov     sp, x1
    ldp     q14, q15, [sp], #32
    ldp     q12, q13, [sp], #32
    ldp     q10, q11, [sp], #32
    ldp     q8,  q9,  [sp], #32
    ldp     x29, x30, [sp], #16
    ldp     x27, x28, [sp], #16
    ldp     x25, x26, [sp], #16
    ldp     x23, x24, [sp], #16
    ldp     x21, x22, [sp], #16
    ldp     x19, x20, [sp], #16
    ret

// Entry point woven into every fresh thread's initial frame (via the x30
// slot). Exception entry masked IRQs, and a cooperative yield saves DAIF
// with IRQs off too — so a brand-new thread always arrives here with IRQs
// masked and must unmask them before doing any real work. (Threads resumed
// through the IRQ path instead get their DAIF back from eret/SPSR.)
thread_start:
    msr     daifclr, #2
    bl      swift_thread_bootstrap        // Never returns
1:  wfi
    b       1b

// UInt thread_start_address() — lets Scheduler.spawn fill the initial x30.
.globl thread_start_address
thread_start_address:
    adr     x0, thread_start
    ret

// UInt arm_irq_save(): mask IRQs, return the previous DAIF. Nesting-safe
// counterpart to arm_irq_enable/disable — use around critical sections that
// may nest (heap <-> Tasks registry <-> scheduler).
.globl arm_irq_save
arm_irq_save:
    mrs     x0, daif
    msr     daifset, #2
    ret

// void arm_irq_restore(UInt daif): restore a DAIF snapshot from arm_irq_save.
.globl arm_irq_restore
arm_irq_restore:
    msr     daif, x0
    ret
