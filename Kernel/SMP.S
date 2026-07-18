// Secondary CPU bring-up + a global spinlock (Pi-5-profile 4-core virt).

.section .text

// Entry for secondary CPUs started via PSCI CPU_ON.
// x0 = context: pointer whose first word is the cpu id; doubles as the
// initial stack top.
// Flow: CPACR (FP/SIMD on this core) -> smp_secondary_main, which first
// JOINS THE BSP'S TRANSLATION REGIME (replays the captured MAIR/TCR/TTBR0/
// SCTLR — PSCI starts secondaries with the MMU OFF, where memory is
// device-like and unaligned accesses fault), then does the per-core
// GIC/tick/vector init (Interrupts.initCoreInterrupts) and enters
// Scheduler.runCore(cpu:) — Never. Falling through here means a bug.
.globl smp_secondary_entry
smp_secondary_entry:
    mov     sp, x0
    ldr     x19, [sp]               // cpu id
    mov     x9, #(0x3 << 20)        // CPACR_EL1.FPEN: FP/SIMD on this core too
    msr     CPACR_EL1, x9
    isb
    mov     x0, x19
    bl      smp_secondary_main
1:  wfe
    b       1b

// UInt arm_read_mpidr(): raw MPIDR_EL1. The FULL register is returned;
// Swift callers mask (Aff0 = value & 0xFF is the cpu index on QEMU virt).
.globl arm_read_mpidr
arm_read_mpidr:
    mrs     x0, MPIDR_EL1
    ret

// Read-side sysreg helpers for the per-core MMU join (see SMP.swift). The
// write side already exists as the GLOBAL helpers in Kernel/MMU.S
// (mmu_write_mair/tcr/ttbr0/sctlr, mmu_tlbi_vmalle1); the read side for
// SCTLR is mmu_read_sctlr there. These three are read on the BSP only, to
// capture the live translation config the secondaries will replay.
.globl arm_read_mair
arm_read_mair:
    mrs     x0, MAIR_EL1
    ret

.globl arm_read_tcr
arm_read_tcr:
    mrs     x0, TCR_EL1
    ret

.globl arm_read_ttbr0
arm_read_ttbr0:
    mrs     x0, TTBR0_EL1
    ret

// Simple exclusive spinlock (LDAXR/STLXR).
.globl arm_spin_lock
arm_spin_lock:
    mov     w9, #1
1:
    ldaxr   w10, [x0]
    cbnz    w10, 1b
    stlxr   w10, w9, [x0]
    cbnz    w10, 1b
    dmb     ish
    ret

.globl arm_spin_unlock
arm_spin_unlock:
    dmb     ish
    stlr    wzr, [x0]
    ret

.globl arm_klog_lock_addr
arm_klog_lock_addr:
    adrp    x0, klog_lock
    add     x0, x0, :lo12:klog_lock
    ret

.globl arm_smp_entry_addr
arm_smp_entry_addr:
    adrp    x0, smp_secondary_entry
    add     x0, x0, :lo12:smp_secondary_entry
    ret

.data
.align 2
.globl klog_lock
klog_lock:
    .word 0
