// Secondary CPU bring-up + a global spinlock (Pi-5-profile 4-core virt).

.section .text

// Entry for secondary CPUs started via PSCI CPU_ON.
// x0 = context: pointer whose first word is the cpu id; doubles as the
// initial stack top.
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
