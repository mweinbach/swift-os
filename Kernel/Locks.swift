// ============================================================================
// Locks — cross-core locking primitives (Pi-5-profile 4-core virt).
//
// armIrqSave/armIrqRestore mask IRQs on the CURRENT core only; with four
// Cortex-A76 cores online that protects nothing cross-core. This layer pairs
// the DAIF save/restore with the arm_spin_lock/arm_spin_unlock exclusive
// spinlocks (Kernel/SMP.S), giving critical sections that are atomic both
// against preemption on this core AND against concurrent access from other
// cores.
//
// ---------------------------------------------------------------------------
// LOCK HIERARCHY (acquire in this order, release in reverse):
//
//     1. sched / tasks   scheduler run queues + task registry locks
//     2. klog            the klog_lock spinlock in SMP.S (serial log lines)
//     3. heap            KernelHeap (page bitmap + malloc arena) — LOWEST
//
// Rules:
//   - NEVER acquire a lock while holding one that sits BELOW it in this
//     order. You may acquire a lower lock while holding a higher one.
//   - klog MAY be called while holding the sched/tasks locks: klog's
//     BootLog.add allocates, which takes the heap lock — allowed, since the
//     heap lock is the lowest rung.
//   - NEVER klog() or allocate while holding the heap lock. klog takes
//     klog_lock and then allocates — re-entering the (non-recursive) heap
//     spinlock self-deadlocks, and the inverted order (heap > klog > heap)
//     deadlocks cross-core. Heap diagnostics stay UART-literal-only.
//   - The panic path takes NO locks at all: any lock could be held by a
//     dead core, and spinning on it would silence the crash dump.
//   - IRQ context: no allocation, no lock acquisition — counters + MMIO
//     only. The *IrqSave variants exist so that a timer IRQ on the SAME
//     core can't context-switch into a second user of a held lock.
// ---------------------------------------------------------------------------
//
// All spinlocks here are NON-recursive: re-taking a lock your own core
// already holds spins forever. The lock words are plain statics in BSS —
// never heap storage (the heap lock guards the heap; it cannot live in it).
// Taking the address of the statics below is safe; their initialization is
// trivial and they are first touched on the BSP during boot, long before
// any secondary runs shared-state code.

enum Locks {
    // Backing storage (BSS). Never accessed directly — use the pointers.
    private static var heapWord:  UInt = 0
    private static var tasksWord: UInt = 0
    private static var schedWord: UInt = 0

    /// KernelHeap page-bitmap + malloc arena lock (lowest rung).
    static var heap: UnsafeMutablePointer<UInt> { UnsafeMutablePointer(&heapWord) }
    /// Task registry lock (rung 1, shared with sched).
    static var tasks: UnsafeMutablePointer<UInt> { UnsafeMutablePointer(&tasksWord) }
    /// Scheduler run-queue lock (rung 1, shared with tasks).
    static var sched: UnsafeMutablePointer<UInt> { UnsafeMutablePointer(&schedWord) }

    /// Mask IRQs on this core, then spin until the lock is acquired.
    /// Returns the saved DAIF state for unlockIrqRestore. Nesting-safe with
    /// respect to IRQ state (each pair saves/restores its own DAIF), but NOT
    /// recursive on the same lock word.
    @inline(__always)
    static func lockIrqSave(_ word: UnsafeMutablePointer<UInt>) -> UInt {
        let daif = armIrqSave()
        armSpinLock(UInt(bitPattern: word))
        return daif
    }

    /// Release the lock, then restore the DAIF state saved by lockIrqSave.
    @inline(__always)
    static func unlockIrqRestore(_ word: UnsafeMutablePointer<UInt>, _ daif: UInt) {
        armSpinUnlock(UInt(bitPattern: word))
        armIrqRestore(daif)
    }

    /// Spin until the lock is acquired (IRQ state untouched). Only for
    /// sections never entered from IRQ context and never nested inside an
    /// irqsave section that could be preempted into a second taker.
    @inline(__always)
    static func lock(_ word: UnsafeMutablePointer<UInt>) {
        armSpinLock(UInt(bitPattern: word))
    }

    /// Release a lock taken with lock(_:).
    @inline(__always)
    static func unlock(_ word: UnsafeMutablePointer<UInt>) {
        armSpinUnlock(UInt(bitPattern: word))
    }
}
