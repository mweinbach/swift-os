// Cooperative kernel task registry. v1 tracks real tasks for accounting
// (the scheduler hooks noteRun from the main loop / timer tick).
//
// List mutations (register/unregister) are IRQ-atomic via
// armIrqSave/armIrqRestore: with the preemptive scheduler enabled, the
// timer IRQ runs on any thread at any time, and Scheduler accounting feeds
// noteRun through the per-frame drain in foldCpuPercent.

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

    @discardableResult
    static func register(name: String, memoryMB: Double = 2) -> Int {
        let daif = armIrqSave()
        let id = nextID
        nextID += 1
        list.append(KernelTask(id: id, name: name, state: "S",
                               cpuTicks: 0, memoryMB: memoryMB,
                               cpuPercent: 0, baselineCPU: 0))
        armIrqRestore(daif)
        return id
    }

    static func unregister(id: Int) {
        let daif = armIrqSave()
        list.removeAll { $0.id == id }
        armIrqRestore(daif)
    }

    static func noteRun(id: Int, ticks: UInt64 = 1) {
        for i in list.indices where list[i].id == id {
            list[i].cpuTicks &+= ticks
            return
        }
    }

    /// Called once per scheduler tick by KernelServices to fold raw tick
    /// counts into smoothed percentages.
    static func foldCpuPercent(totalDelta: UInt64) {
        // Fold the scheduler's IRQ-accounted per-thread ticks into the
        // registry first (thread context here, unlike the timer IRQ
        // itself). Returns 0 and changes nothing when the scheduler is off.
        let total = totalDelta &+ Scheduler.drainTickAccounting()
        for i in list.indices {
            let delta = list[i].cpuTicks
            list[i].cpuTicks = 0
            let inst = total > 0 ? Double(delta) * 100.0 / Double(total) : 0
            list[i].cpuPercent = list[i].cpuPercent * 0.7 + inst * 0.3
            list[i].state = list[i].cpuPercent > 1.5 ? "R" : "S"
        }
    }
}
