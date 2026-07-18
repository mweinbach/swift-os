// EL0 drop trampolines and kernel-resume stash for userspace
// (Kernel/Userspace.swift has the design + syscall ABI). Two flavours:
//   - arm_run_el0: the legacy SYNCHRONOUS demo (runDemo, main thread
//     only). Saves the kernel's callee-saved registers on the current
//     (kernel) stack, stashes the SP in el0_kernel_save, then erets into
//     EL0t with IRQs unmasked. The only return path is the teardown
//     branch of sync_lower_entry (Vectors.S), taken on the user's exit
//     syscall or on a user fault, which reloads the stashed SP and jumps
//     to el0_exited with a marker in x0 — from the Swift caller's
//     perspective arm_run_el0 simply returns a UInt64.
//   - arm_drop_el0 (below): the SCHEDULED user thread's one-way drop.
//     No frame, no stash, no return — terminal outcomes are resolved by
//     the scheduler, so any number of them can be at EL0 concurrently
//     (one per core), which a single global stash could never survive.

.data
.balign 8
.globl el0_kernel_save
el0_kernel_save:
    .skip   16                          // [0]=SP in arm_run_el0, [8]=DAIF —
                                        // legacy runDemo only; scheduled
                                        // threads never read or write it

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

// void arm_drop_el0(UInt64 entry, UInt64 userSP, UInt64 mode, UInt64 serial)
// — returns Never. The SCHEDULED user thread's one-way drop to EL0
// (Kernel/Userspace.swift has the design). Unlike arm_run_el0 there is no
// callee-saved frame, no kernel-SP stash and no way back: a scheduled
// thread leaves EL0 only through exceptions, and its terminal outcomes —
// the exit syscall, a user fault, or a kill from another core — are
// resolved by the scheduler (UserProcess.handleSyncFromEL0 -> Scheduler.exit,
// or the next schedule point's zombie demotion), never by returning here.
// Its kernel stack is abandoned wholesale and freed by the reaper.
//   mode/serial land in EL0's x0/x1 — the blob's only arguments (mode 0 =
//   legacy short demo, nonzero = scheduled long run; serial = user<N>'s N).
// SP_EL1 keeps its current value: it is this thread's kernel stack top for
// every later SVC/IRQ frame, and grows down from here.
.globl arm_drop_el0
arm_drop_el0:
    msr     SP_EL0, x1
    msr     ELR_EL1, x0
    msr     SPSR_EL1, xzr               // EL0t (M=0b0000), DAIF clear: IRQs on
    mov     x0, x2                      // run mode -> the blob's x0
    mov     x1, x3                      // process serial -> the blob's x1    // Zero every other GPR EL0 will observe — don't leak kernel state.
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
    mov     x19, xzr
    mov     x20, xzr
    mov     x21, xzr
    mov     x22, xzr
    mov     x23, xzr
    mov     x24, xzr
    mov     x25, xzr
    mov     x26, xzr
    mov     x27, xzr
    mov     x28, xzr
    mov     x29, xzr
    mov     x30, xzr
    isb
    eret                                // one-way: EL0 until thread death

// UInt arm_read_sp_el0() / void arm_write_sp_el0(UInt sp)
// SP_EL0 is PER-CORE state, so for scheduled user threads it is also
// PER-THREAD context: the scheduler's switch hook saves the outgoing user
// thread's SP_EL0 into its TCB and restores the incoming one's — otherwise
// a thread resumed on a core that never dropped it inherits whatever stale
// SP_EL0 that core had (another process's, the legacy demo's, or reset
// garbage), and its next EL0 stack access faults wildly. Read/written only
// at EL1 with the thread stopped (switch path, sched lock held).
.globl arm_read_sp_el0
arm_read_sp_el0:
    mrs     x0, SP_EL0
    ret

.globl arm_write_sp_el0
arm_write_sp_el0:
    msr     SP_EL0, x0
    ret

// UInt64 arm_read_far_el1() — FAR_EL1 for the EL0 fault diagnostic
// (Kernel/Userspace.swift; Vectors.S only passes ESR + the frame).
.globl arm_read_far_el1
arm_read_far_el1:
    mrs     x0, FAR_EL1
    ret
