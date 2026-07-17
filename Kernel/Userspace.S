// EL0 drop trampoline and kernel-resume stash for the userspace demo
// (Kernel/Userspace.swift has the design + syscall ABI).
//
// arm_run_el0(entry, userSP) saves the kernel's callee-saved registers on
// the current (kernel) stack, stashes the SP in el0_kernel_save, then erets
// into EL0t with IRQs unmasked. There is no way back through this function
// itself: the only return path is the teardown branch of sync_lower_entry
// (Vectors.S), taken on the user's exit syscall or on a user fault, which
// reloads the stashed SP and jumps to el0_exited with a marker in x0 —
// from the Swift caller's perspective arm_run_el0 simply returns a UInt64.
//
// Single global stash = single active EL0 run; UserProcess.runActive
// enforces that (runDemo is only ever called synchronously from the shell
// on the main thread anyway).

.data
.balign 8
.globl el0_kernel_save
el0_kernel_save:
    .skip   16                          // [0]=SP in arm_run_el0, [8]=DAIF

.text

// UInt64 arm_run_el0(UInt64 entry, UInt64 userSP)
//   entry  = EL0 entry point (start of the blob page)
//   userSP = top of the EL0 stack
// Returns the teardown marker: 1 = user called exit, 2 = user faulted.
.globl arm_run_el0
arm_run_el0:
    sub     sp, sp, #128
    stp     x19, x20, [sp, #0]
    stp     x21, x22, [sp, #16]
    stp     x23, x24, [sp, #32]
    stp     x25, x26, [sp, #48]
    stp     x27, x28, [sp, #64]
    stp     x29, x30, [sp, #80]
    adr     x9, el0_kernel_save
    mov     x10, sp
    mrs     x11, daif                   // teardown must restore our PSTATE:
    stp     x10, x11, [x9]              // exception entry masks DAIF, and the
                                        // teardown path has no eret to undo it
    msr     SP_EL0, x1
    msr     ELR_EL1, x0
    msr     SPSR_EL1, xzr               // EL0t (M=0b0000), DAIF clear: IRQs on
    // Zero every GPR EL0 will observe — don't leak kernel register state.
    mov     x0, xzr
    mov     x1, xzr
    mov     x2, xzr
    mov     x3, xzr
    mov     x4, xzr
    mov     x5, xzr
    mov     x6, xzr
    mov     x7, xzr
    mov     x8, xzr
    mov     x9, xzr
    mov     x10, xzr
    mov     x11, xzr
    mov     x12, xzr
    mov     x13, xzr
    mov     x14, xzr
    mov     x15, xzr
    mov     x16, xzr
    mov     x17, xzr
    mov     x18, xzr
    mov     x30, xzr
    isb
    eret                                // never returns here — see el0_exited

// Kernel-side resume point, entered from sync_lower_entry's teardown path
// with SP already restored to arm_run_el0's frame and x0 = marker. Pops
// the callee-saved frame and returns the marker to the Swift caller.
.globl el0_exited
el0_exited:
    ldp     x19, x20, [sp, #0]
    ldp     x21, x22, [sp, #16]
    ldp     x23, x24, [sp, #32]
    ldp     x25, x26, [sp, #48]
    ldp     x27, x28, [sp, #64]
    ldp     x29, x30, [sp, #80]
    add     sp, sp, #128
    ret
