// Preemptive round-robin kernel thread scheduler.
//
// Threads are TCBs in a fixed 16-slot table kept in RAW HEAP MEMORY (one
// page from allocPages, bound to TCB, never reallocated). This is load-
// bearing: the table is read and written from both thread context and the
// timer IRQ on different threads, so it must stay clear of Swift's shared
// storage machinery — no Swift Array (copy-on-write + subscript access
// tracking across a context switch), and a strictly POD TCB (no String or
// closure fields: their retain/release is not atomic across a preemption
// boundary and corrupts when an IRQ hits mid-access). Entry closures live
// in a side array that is only ever touched in thread context (spawn and
// first start), and task names live only in the Tasks registry (ps).
//
// A context switch is arm_switch_context (Scheduler.S): it pushes the
// callee-saved GPRs x19-x30 and NEON q8-q15 on the current stack, stores
// the SP into the outgoing TCB, loads the incoming TCB's SP, pops the same
// frame and returns. For a fresh thread that "return" lands in
// thread_start, which unmasks IRQs and calls swift_thread_bootstrap ->
// the thread's entry closure. A thread preempted from the timer IRQ is
// resumed mid-handler: its switch call returns, it unwinds through
// swift_irq_dispatch back to irq_entry, restores x0-x18/x30 from the frame
// the stub pushed, and erets to exactly where it was interrupted — so the
// full register state of the interrupted thread rides on its own stack.
//
// Preemption: Interrupts.handleIrq calls Scheduler.onTimerTick AFTER the
// GIC EOI. The order matters: while the timer PPI is still active (not
// EOI'd) the GIC will not re-signal it, so a switch that deferred EOI until
// the preempted thread runs again would starve the tick — and the scheduler
// itself is driven by that tick. EOI first, switch second.
//
// CPU accounting reaches ps / System Monitor via drainTickAccounting(),
// which Tasks.foldCpuPercent calls once per frame on the main thread
// (thread context — the IRQ path itself never touches the Tasks registry).
//
// Everything here is a no-op unless Config.enableScheduler is true.

@_silgen_name("arm_switch_context")
private func armSwitchContext(_ saveSP: UnsafeMutablePointer<UInt>, _ newSP: UInt)
@_silgen_name("thread_start_address")
private func threadStartAddress() -> UInt
@_silgen_name("arm_irq_save")
func armIrqSave() -> UInt
@_silgen_name("arm_irq_restore")
func armIrqRestore(_ daif: UInt)

enum Scheduler {
    /// Hardware cap on concurrent kernel threads (fixed table, never grows).
    static let maxThreads = 16
    /// Timer ticks a thread may run before preemption (5 x 10 ms = 50 ms).
    static let quantumTicks = 5

    /// sleeping flips back to runnable from the timer IRQ once
    /// Interrupts.uptimeTicks() reaches wakeTick.
    private enum ThreadState: UInt8 {
        case runnable, running, sleeping
    }

    /// Thread control block. STRICTLY POD — see the file header: no String,
    /// no closures, nothing with a refcount.
    private struct TCB {
        var used = false
        var state = ThreadState.runnable
        var stackBase: UInt = 0         // 0 for thread 0 (boot stack in BSS)
        var stackPages = 0
        var sp: UInt = 0                // saved SP, valid while not running
        var wakeTick: UInt64 = 0
        var ticksRan: UInt64 = 0        // tick count from the timer IRQ
        var accountedTicks: UInt64 = 0  // ticks already drained into Tasks
        var taskID = 0                  // Tasks registry id (ps/System Monitor)
    }

    /// Raw TCB table: one heap page, allocated and bound in initScheduler.
    /// Accessed only through this pointer — plain loads/stores on both the
    /// thread and IRQ paths, no Swift container semantics involved.
    private static var tcbs: UnsafeMutablePointer<TCB>?

    /// Thread entry closures by slot. THREAD CONTEXT ONLY: written by
    /// spawn, read once by swift_thread_bootstrap at a thread's first
    /// start. Never touched from the IRQ path or across a switch boundary.
    private static var entries = [(() -> Never)?](repeating: nil, count: maxThreads)

    private static var current = 0
    private static var initialized = false
    private static var ticksSinceSwitch = 0

    // arm_switch_context frame: see the layout comment in Scheduler.S.
    private static let switchFrameSize = 224
    private static let switchFrameX30Offset = 136

    /// Demo counter bumped by the kworker thread once per second.
    static private(set) var kworkerCounter: UInt64 = 0

    // MARK: - Init

    /// Bring up the scheduler: allocate the TCB table, adopt the boot/main
    /// thread as slot 0, and spawn the idle + kworker threads. Call once,
    /// any time after KernelHeap.initHeap (before or after
    /// Interrupts.initInterrupts). No-op unless Config.enableScheduler.
    static func initScheduler() {
        guard Config.enableScheduler, !initialized else { return }

        // One page holds 16 TCBs with room to spare; zero it, bind it, and
        // materialize a default TCB into every slot.
        guard let page = KernelHeap.allocPages(1),
              let raw = UnsafeMutableRawPointer(bitPattern: page) else {
            kpanic("scheduler: could not allocate TCB table")
        }
        var p = page
        let end = page &+ 4096
        while p < end {
            UnsafeMutablePointer<UInt64>(bitPattern: p)!.pointee = 0
            p &+= 8
        }
        let table = raw.bindMemory(to: TCB.self, capacity: maxThreads)
        var i = 0
        while i < maxThreads {
            table[i] = TCB()
            i &+= 1
        }
        tcbs = table

        table[0].used = true
        table[0].state = .running
        table[0].taskID = Tasks.register(name: "main", memoryMB: 1)
        current = 0
        initialized = true

        _ = spawn(name: "idle", stackPages: 1, entry: idleMain)
        _ = spawn(name: "kworker", stackPages: 2, entry: kworkerMain)

        klog("[sched] scheduler up: main + idle + kworker, quantum 50 ms")
    }

    // MARK: - Thread creation

    /// Create a thread: allocate its stack and fabricate an initial switch
    /// frame so the first context switch to it "returns" into thread_start
    /// -> entry(). Returns the thread id (table slot), or -1 when the table
    /// is full or the stack allocation fails. Thread context only — this
    /// allocates (heap page pool + Tasks registry).
    @discardableResult
    static func spawn(name: String, stackPages: Int, entry: @escaping () -> Never) -> Int {
        guard Config.enableScheduler, initialized, stackPages > 0 else { return -1 }
        guard let tcbs else { return -1 }

        // Slot 0 belongs to the boot thread. The scan races safely with the
        // IRQ-side table walk because `used` is published last, after every
        // other field (single CPU: the IRQ handler observes program order).
        var slot = -1
        var i = 1
        while i < maxThreads {
            if !tcbs[i].used { slot = i; break }
            i &+= 1
        }
        guard slot >= 0 else { return -1 }
        guard let base = KernelHeap.allocPages(stackPages) else { return -1 }

        let taskID = Tasks.register(name: name,
                                    memoryMB: Double(stackPages * 4096) / 1_048_576.0)

        // Fabricated arm_switch_context frame at the stack top: all zero
        // except the x30 slot -> thread_start (Scheduler.S has the layout).
        let top = base &+ (UInt(stackPages) << 12)
        let sp0 = top &- UInt(switchFrameSize)
        var p = sp0
        while p < top {
            UnsafeMutablePointer<UInt64>(bitPattern: p)!.pointee = 0
            p &+= 8
        }
        UnsafeMutablePointer<UInt64>(bitPattern: sp0 &+ UInt(switchFrameX30Offset))!
            .pointee = UInt64(threadStartAddress())

        tcbs[slot].state = .runnable
        tcbs[slot].stackBase = base
        tcbs[slot].stackPages = stackPages
        tcbs[slot].sp = sp0
        tcbs[slot].wakeTick = 0
        tcbs[slot].ticksRan = 0
        tcbs[slot].accountedTicks = 0
        tcbs[slot].taskID = taskID
        entries[slot] = entry               // thread-context side table
        tcbs[slot].used = true              // publish last
        return slot
    }

    // MARK: - Cooperative primitives

    /// Voluntarily hand the CPU to the next runnable thread. Safe to call
    /// with IRQs in any state — the entry DAIF is restored on return.
    static func yield() {
        guard Config.enableScheduler, initialized else { return }
        let daif = armIrqSave()
        switchToNextRunnable()
        armIrqRestore(daif)
    }

    /// Block the current thread for `ticks` timer ticks (10 ms each):
    /// mark sleeping, switch away, and let the timer IRQ flip the state
    /// back to runnable once the wake tick has passed.
    static func sleep(ticks: UInt64) {
        guard Config.enableScheduler, initialized, let tcbs else { return }
        let me = current
        let wake = Interrupts.uptimeTicks() &+ ticks
        while true {
            let daif = armIrqSave()
            if Interrupts.uptimeTicks() >= wake {
                tcbs[me].state = .running
                armIrqRestore(daif)
                return
            }
            tcbs[me].wakeTick = wake
            tcbs[me].state = .sleeping
            switchToNextRunnable()
            armIrqRestore(daif)
        }
    }

    /// Table slot of the currently running thread (0 = boot/main thread).
    static var currentThreadID: Int { current }

    // MARK: - Timer IRQ hook (IRQ CONTEXT: counters + fixed-table writes only)

    /// Called from Interrupts.handleIrq on every timer tick, after the GIC
    /// EOI. Accounts one tick to the running thread, wakes due sleepers,
    /// and preempts round-robin every quantumTicks. Zero allocation, and
    /// only raw loads/stores on the TCB table.
    static func onTimerTick() {
        guard Config.enableScheduler, initialized, let tcbs else { return }

        tcbs[current].ticksRan &+= 1

        let now = Interrupts.uptimeTicks()
        var i = 0
        while i < maxThreads {
            if tcbs[i].used, tcbs[i].state == .sleeping, now >= tcbs[i].wakeTick {
                tcbs[i].state = .runnable
            }
            i &+= 1
        }

        ticksSinceSwitch &+= 1
        if ticksSinceSwitch >= quantumTicks {
            ticksSinceSwitch = 0
            switchToNextRunnable()
        }
    }

    // MARK: - Accounting drain (thread context only)

    /// Move IRQ-accounted per-thread ticks into the Tasks registry.
    /// Called from Tasks.foldCpuPercent once per frame on the main thread —
    /// never from the IRQ path. Returns the total ticks drained so the
    /// caller's per-frame cpu% denominator stays exact.
    static func drainTickAccounting() -> UInt64 {
        guard Config.enableScheduler, initialized, let tcbs else { return 0 }
        var total: UInt64 = 0
        var i = 0
        while i < maxThreads {
            if tcbs[i].used {
                let d = tcbs[i].ticksRan &- tcbs[i].accountedTicks
                if d > 0 {
                    tcbs[i].accountedTicks = tcbs[i].ticksRan
                    Tasks.noteRun(id: tcbs[i].taskID, ticks: d)
                    total &+= d
                }
            }
            i &+= 1
        }
        return total
    }

    /// Entry closure of the running thread, for swift_thread_bootstrap.
    /// Thread context (first start only).
    static func currentThreadEntry() -> () -> Never {
        if let entry = entries[current] {
            return entry
        }
        kpanic("scheduler: running thread has no entry")
    }

    // MARK: - Round-robin switch

    /// Switch to the next runnable slot after `current`. Caller must have
    /// IRQs masked (the timer IRQ handler always does; yield/sleep use
    /// armIrqSave). No allocation; raw table loads/stores only.
    private static func switchToNextRunnable() {
        guard let tcbs else { return }
        var next = current
        var step = 1
        while step < maxThreads {
            let cand = (current &+ step) % maxThreads
            if tcbs[cand].used, tcbs[cand].state == .runnable {
                next = cand
                break
            }
            step &+= 1
        }
        guard next != current else { return }
        let prev = current
        if tcbs[prev].state == .running { tcbs[prev].state = .runnable }
        tcbs[next].state = .running
        current = next
        let newSP = tcbs[next].sp
        armSwitchContext(&tcbs[prev].sp, newSP)
    }

    // MARK: - Built-in threads

    /// Idle thread: park in wfi. Never sleeps in scheduler terms, so the
    /// round-robin always has at least one runnable thread.
    private static func idleMain() -> Never {
        while true { armWfi() }
    }

    /// Demo kernel worker: quietly bump a counter once a second.
    private static func kworkerMain() -> Never {
        while true {
            kworkerCounter &+= 1
            sleep(ticks: 100)
        }
    }
}

/// First-frame trampoline for fresh threads (reached from thread_start in
/// Scheduler.S, which has already unmasked IRQs). Never returns.
@_cdecl("swift_thread_bootstrap")
func swiftThreadBootstrap() -> Never {
    Scheduler.currentThreadEntry()()
}
