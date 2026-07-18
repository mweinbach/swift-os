// Cooperative kernel task registry. v1 tracks real tasks for accounting
// (the scheduler hooks noteRun from the main loop / timer ticks).
//
// SMP locking: list mutations and folds are guarded by Locks.tasks
// (cross-core spinlock + IRQ save/restore) — with per-core scheduling,
// register/unregister run on whichever core spawns or reaps a thread, and
// the scheduler's accounting feeds noteRun through the per-frame drain in
// foldCpuPercent. The only cross-lock order in the kernel is sched ->
// tasks (Scheduler.drainTickAccounting -> noteRun); nothing holding
// Locks.tasks may take Locks.sched, so foldCpuPercent drains BEFORE
// taking the tasks lock. List appends allocate (heap lock) — legal:
// heap is the lowest rung (sched/tasks > klog > heap).

struct KernelTask {
    let id: Int
    var name: String
    var state: String        // "R" running, "S" sleeping
    var cpuTicks: UInt64     // scheduler ticks attributed to this task
    var memoryMB: Double     // attributed memory (static estimate for now)
    var cpuPercent: Double   // smoothed, computed by KernelServices.tick
    var baselineCPU: Double
}

enum Tasks {
    static private(set) var list: [KernelTask] = []
    static private var nextID = 1
    /// BSP tickCount at the previous fold (per-core %CPU denominator).
    private static var lastFoldTick: UInt64 = 0

    @discardableResult
    static func register(name: String, memoryMB: Double = 2) -> Int {
        let daif = Locks.lockIrqSave(Locks.tasks)
        let id = nextID
        nextID += 1
        list.append(KernelTask(id: id, name: name, state: "S",
                               cpuTicks: 0, memoryMB: memoryMB,
                               cpuPercent: 0, baselineCPU: 0))
        Locks.unlockIrqRestore(Locks.tasks, daif)
        return id
    }

    static func unregister(id: Int) {
        let daif = Locks.lockIrqSave(Locks.tasks)
        list.removeAll { $0.id == id }
        Locks.unlockIrqRestore(Locks.tasks, daif)
    }

    static func noteRun(id: Int, ticks: UInt64 = 1) {
        let daif = Locks.lockIrqSave(Locks.tasks)
        for i in list.indices where list[i].id == id {
            list[i].cpuTicks &+= ticks
            break
        }
        Locks.unlockIrqRestore(Locks.tasks, daif)
    }

    /// Lock-taking copy of the registry. Direct `list` iteration is safe
    /// only where it always ran (main thread); readers that can race a
    /// cross-core register/unregister should take a snapshot instead
    /// (copy-on-write keeps the retained buffer stable under mutation).
    static func snapshot() -> [KernelTask] {
        let daif = Locks.lockIrqSave(Locks.tasks)
        let copy = list
        Locks.unlockIrqRestore(Locks.tasks, daif)
        return copy
    }

    /// Called once per scheduler tick by KernelServices to fold raw tick
    /// counts into smoothed percentages.
    ///
    /// Linux-style per-core normalization: 100% == one full core. With the
    /// scheduler active the denominator is the ticks elapsed on ONE core in
    /// the fold period (BSP tickCount delta — per-core ticks all run at the
    /// same 100 Hz): a thread pegging one core reads ~100, four threads
    /// pegging four cores sum to ~400. With the scheduler off there is no
    /// per-thread tick accounting, so keep the old share-of-total semantics.
    static func foldCpuPercent(totalDelta: UInt64) {
        // Fold the scheduler's IRQ-accounted per-thread ticks into the
        // registry first (thread context here, unlike the timer IRQ
        // itself), WITHOUT holding the tasks lock — the drain takes
        // Locks.sched and re-enters noteRun (sched -> tasks order).
        // Returns 0 and changes nothing when the scheduler is off.
        let drained = Scheduler.drainTickAccounting()

        let now = Interrupts.uptimeTicks()
        let elapsed: UInt64
        if Scheduler.isActive {
            elapsed = now &- lastFoldTick
            lastFoldTick = now
        } else {
            elapsed = totalDelta &+ drained
        }

        let daif = Locks.lockIrqSave(Locks.tasks)
        // Tick-weighted EMA: fold windows vary in length (the fold runs on
        // the main thread, so folds cluster when main is current), and a
        // flat EMA over inst values converges to the share of FOLDS, not
        // the share of TIME — bursty 0-or-100 inst values at ~1-tick
        // windows bias toward whoever runs near fold time. Weighting each
        // fold by its window length makes the average time-correct: a
        // thread pegging one core still reads ~100, idles read ~0.
        let alpha = elapsed > 0 ? Double(elapsed) / (Double(elapsed) + 25.0) : 0
        for i in list.indices {
            let delta = list[i].cpuTicks
            list[i].cpuTicks = 0
            let inst = elapsed > 0 ? Double(delta) * 100.0 / Double(elapsed) : 0
            list[i].cpuPercent += (inst - list[i].cpuPercent) * alpha
            list[i].state = list[i].cpuPercent > 1.5 ? "R" : "S"
        }
        Locks.unlockIrqRestore(Locks.tasks, daif)
    }
}
