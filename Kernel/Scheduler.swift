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
// Stack overflow canaries: every spawned thread's stack is filled with
// 0xAA and carries a 16-byte canary (two UInt64 magics) at its BASE.
// AArch64 stacks grow down, so an overflow clobbers the base last before
// running off the allocation — the canary is the tripwire. The timer tick
// audits every live thread's canary every ~100 ms (fixed table walk, two
// loads per slot, no allocation) and panics the kernel with the offending
// thread id on the first mismatch; the per-thread panic note is built at
// spawn (thread context) so the IRQ-side audit never allocates. The boot
// thread (slot 0) is NOT audited: its stack belongs to Boot.S, which
// exports no base symbol, so no canary is planted there.
//
// Thread lifecycle: entry closures are () -> Never BY CONSTRUCTION —
// returning is impossible (there is nothing to return to; thread_start
// parks forever), so a thread that wants out calls Scheduler.exit(), which
// marks it zombie and switches away for good. kill(id:) does the same to
// another thread (it refuses the boot thread and the caller). A zombie is
// never scheduled again (the wake scan only revives .sleeping, the round-
// robin only picks .runnable); its slot and stack are reclaimed by
// reapZombies() from idle/kworker THREAD context — never from the IRQ
// path, since reclaiming frees pages and logs. Note that exit() abandons
// the thread's call stack mid-flight: nothing unwinds, and any resources
// the thread held stay held (POSIX pthread_exit semantics, minus cleanup
// handlers). The abandoned bootstrap frame also keeps one reference to
// the entry-closure box alive forever — one small box per exited thread,
// bounded and harmless.
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

    /// Stack-fill pattern (0xAA bytes) and the overflow canary planted at
    /// the base of every spawned stack (two UInt64 magics, 16 bytes).
    private static let stackFill: UInt64 = 0xAAAA_AAAA_AAAA_AAAA
    private static let canaryMagic0: UInt64 = 0xDEAD_BEEF_CAFE_BABE
    private static let canaryMagic1: UInt64 = 0x5AC1_ED5E_C0FF_EE11
    /// Canary audit cadence: every 10 timer ticks = ~100 ms.
    private static let canaryCheckIntervalTicks = 10
    /// kworker health-loop cadences, in 100 Hz timer ticks.
    private static let heapValidateIntervalTicks: UInt64 = 1000   // ~10 s
    private static let heapStatIntervalTicks: UInt64 = 6000       // ~60 s

    /// sleeping flips back to runnable from the timer IRQ once
    /// Interrupts.uptimeTicks() reaches wakeTick. zombie (exit()/kill())
    /// never runs again and is reclaimed by reapZombies().
    private enum ThreadState: UInt8 {
        case runnable, running, sleeping, zombie
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

    /// Per-slot panic note for the canary audit ("stack overflow in
    /// thread N"). Written by spawn/reapZombies in thread context; the
    /// IRQ-side audit only ever READS it, and only on a canary trip —
    /// which is terminal (kpanic), so no allocation happens on the IRQ
    /// path and the read can race with nothing that matters.
    private static var panicNotes = [String](repeating: "", count: maxThreads)

    private static var current = 0
    private static var initialized = false
    private static var ticksSinceSwitch = 0
    private static var ticksSinceCanaryCheck = 0

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

    /// Create a thread: allocate its stack, fill it with 0xAA, plant the
    /// overflow canary at the base, and fabricate an initial switch frame
    /// so the first context switch to it "returns" into thread_start ->
    /// entry(). Returns the thread id (table slot), or -1 when the table
    /// is full or the stack allocation fails. Thread context only — this
    /// allocates (heap page pool + Tasks registry).
    ///
    /// Hardening notes:
    /// - The whole sequence runs with IRQs masked: an unmasked
    ///   scan...preempt...publish window would let two concurrent spawns
    ///   double-book the same slot. Everything inside is safe under masked
    ///   IRQs (heap, Tasks registry and the closure/String stores are all
    ///   internally IRQ-atomic or plain memory writes).
    /// - Stack-alloc failure unwinds cleanly to -1: no TCB field, side
    ///   table, or Tasks registry entry has been touched at that point.
    /// - A zero-length name registers as "thread".
    @discardableResult
    static func spawn(name: String, stackPages: Int, entry: @escaping () -> Never) -> Int {
        guard Config.enableScheduler, initialized, stackPages > 0 else { return -1 }
        guard let tcbs else { return -1 }

        let daif = armIrqSave()
        defer { armIrqRestore(daif) }

        // Slot 0 belongs to the boot thread. `used` is published last,
        // after every other field (single CPU: the IRQ handler observes
        // program order).
        var slot = -1
        var i = 1
        while i < maxThreads {
            if !tcbs[i].used { slot = i; break }
            i &+= 1
        }
        guard slot >= 0 else { return -1 }              // table full
        guard let base = KernelHeap.allocPages(stackPages) else { return -1 }

        let taskName = name.isEmpty ? "thread" : name
        let taskID = Tasks.register(name: taskName,
                                    memoryMB: Double(stackPages * 4096) / 1_048_576.0)

        // Fill 0xAA so fresh stack reads back a known pattern, then plant
        // the canary at the very bottom (overflow tripwire: stacks grow
        // down), then fabricate the arm_switch_context frame at the top
        // (Scheduler.S has the layout). The frame sits at the top and the
        // canary at the base, so zeroing the frame cannot touch it.
        let top = base &+ (UInt(stackPages) << 12)
        var p = base
        while p < top {
            UnsafeMutablePointer<UInt64>(bitPattern: p)!.pointee = stackFill
            p &+= 8
        }
        UnsafeMutablePointer<UInt64>(bitPattern: base)!.pointee = canaryMagic0
        UnsafeMutablePointer<UInt64>(bitPattern: base &+ 8)!.pointee = canaryMagic1

        let sp0 = top &- UInt(switchFrameSize)
        p = sp0
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
        panicNotes[slot] = "stack overflow in thread \(slot)"
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

    // MARK: - Thread termination (exit / kill / reap)

    /// Terminate the CALLING thread: mark it zombie and switch away for
    /// good. The slot stays allocated until reapZombies() reclaims it from
    /// idle/kworker thread context. This is the only way out of a thread —
    /// entry closures are () -> Never by construction, so "returning" is
    /// impossible; a thread that is done calls exit(). Abandons the call
    /// stack mid-flight: nothing unwinds, held resources stay held.
    static func exit() -> Never {
        guard Config.enableScheduler, initialized, let tcbs else {
            while true { armWfi() }
        }
        let me = current
        if me == 0 {
            kpanic("scheduler: boot thread cannot exit")
        }
        let daif = armIrqSave()
        tcbs[me].state = .zombie        // switchToNextRunnable only revives .running
        switchToNextRunnable()
        // Unreachable: a zombie is never selected again. If a bug ever
        // lets the switch return, park instead of running dead code.
        armIrqRestore(daif)
        while true { armWfi() }
    }

    /// Mark ANOTHER thread zombie: it is never scheduled again and the
    /// reaper reclaims its slot. Refuses the boot thread (id 0) and the
    /// caller itself (a thread that wants out uses exit()) by returning
    /// false; also false for unused or already-zombie slots. The target is
    /// by definition not running (single CPU, caller != target), so
    /// flipping its state is safe wherever it is parked — mid-yield,
    /// sleeping, or freshly spawned.
    @discardableResult
    static func kill(id: Int) -> Bool {
        guard Config.enableScheduler, initialized, let tcbs else { return false }
        guard id > 0, id < maxThreads, id != current else { return false }
        let daif = armIrqSave()
        if tcbs[id].used, tcbs[id].state != .zombie {
            tcbs[id].state = .zombie    // the wake scan only revives .sleeping
            tcbs[id].wakeTick = 0
            armIrqRestore(daif)
            return true
        }
        armIrqRestore(daif)
        return false
    }

    /// Reclaim every zombie slot: clear the TCB and side tables, free the
    /// stack pages, unregister the task, and log the reclaim. THREAD
    /// CONTEXT ONLY (frees memory, releases references, klogs) — called
    /// from the idle and kworker loops, never from the IRQ path. Two
    /// reapers may run concurrently: the claim (used+zombie -> cleared
    /// slot) happens in one IRQ-masked section, so exactly one reaper wins
    /// each zombie, and spawn/canary/accounting scans never observe a
    /// half-torn-down slot. The stack free happens AFTER the slot stops
    /// being visible, so the canary audit can never read freed pages.
    private static func reapZombies() {
        guard Config.enableScheduler, initialized, let tcbs else { return }
        var i = 1                       // slot 0 (boot thread) can never be a zombie
        while i < maxThreads {
            var base: UInt = 0
            var pages = 0
            var taskID = 0
            var found = false
            let daif = armIrqSave()
            if tcbs[i].used, tcbs[i].state == .zombie {
                found = true
                base = tcbs[i].stackBase
                pages = tcbs[i].stackPages
                taskID = tcbs[i].taskID
                entries[i] = nil
                panicNotes[i] = ""
                tcbs[i] = TCB()         // whole-slot reset, published atomically
            }
            armIrqRestore(daif)
            if found {
                KernelHeap.freePages(base, count: pages)
                Tasks.unregister(id: taskID)
                klog("[sched] reaped thread \(i) (task \(taskID)) — slot free")
            }
            i &+= 1
        }
    }

    // MARK: - Timer IRQ hook (IRQ CONTEXT: counters + fixed-table writes only)

    /// Called from Interrupts.handleIrq on every timer tick, after the GIC
    /// EOI. Accounts one tick to the running thread, wakes due sleepers,
    /// audits stack canaries every ~100 ms, and preempts round-robin every
    /// quantumTicks. Zero allocation, and only raw loads/stores on the TCB
    /// table (plus, on a canary trip, a terminal kpanic).
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

        ticksSinceCanaryCheck &+= 1
        if ticksSinceCanaryCheck >= canaryCheckIntervalTicks {
            ticksSinceCanaryCheck = 0
            checkStackCanaries()
        }

        ticksSinceSwitch &+= 1
        if ticksSinceSwitch >= quantumTicks {
            ticksSinceSwitch = 0
            switchToNextRunnable()
        }
    }

    /// IRQ-side stack-canary audit: verify the 16-byte canary at the base
    /// of every live spawned thread's stack. A mismatch means the thread
    /// already ran past its stack — fatal, panic immediately. No
    /// allocation: the message is precomputed per slot at spawn. Slot 0 is
    /// skipped (boot stack, no canary — Boot.S owns it); zombie slots
    /// still hold their stacks until reaped and stay audited.
    private static func checkStackCanaries() {
        guard let tcbs else { return }
        var i = 1
        while i < maxThreads {
            if tcbs[i].used {
                let base = tcbs[i].stackBase
                if base != 0 {
                    let lo = UnsafeMutablePointer<UInt64>(bitPattern: base)!.pointee
                    let hi = UnsafeMutablePointer<UInt64>(bitPattern: base &+ 8)!.pointee
                    if lo != canaryMagic0 || hi != canaryMagic1 {
                        kpanic(panicNotes[i])
                    }
                }
            }
            i &+= 1
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
    /// armIrqSave). No allocation; raw table loads/stores only. Zombies are
    /// never selected (they are not .runnable), and a .zombie prev is left
    /// zombie — only a .running prev is demoted back to .runnable.
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

    /// Idle thread: reclaim zombie slots, then park in wfi. Never sleeps
    /// in scheduler terms, so the round-robin always has at least one
    /// runnable thread — and the reaper therefore runs at least once per
    /// scheduling round.
    private static func idleMain() -> Never {
        while true {
            reapZombies()
            armWfi()
        }
    }

    /// Kernel worker: second reaper (a killed idle thread must not stop
    /// zombie reclaim), the demo once-a-second counter, and the heap
    /// health loop — KernelHeap.validate() every ~10 s (a failure is
    /// logged exactly once, then the latch silences repeats) and a
    /// one-line heap stat every ~60 s.
    private static func kworkerMain() -> Never {
        var ticksSinceValidate: UInt64 = 0
        var ticksSinceStat: UInt64 = 0
        var heapFailureReported = false
        while true {
            kworkerCounter &+= 1
            reapZombies()
            ticksSinceValidate &+= 100
            ticksSinceStat &+= 100
            if ticksSinceValidate >= heapValidateIntervalTicks {
                ticksSinceValidate = 0
                if !KernelHeap.validate(), !heapFailureReported {
                    heapFailureReported = true
                    klog("[kworker] heap validation FAILED")
                }
            }
            if ticksSinceStat >= heapStatIntervalTicks {
                ticksSinceStat = 0
                let usedMiB = KernelHeap.usedBytes / 1_048_576
                let freeMiB = KernelHeap.freePageCount * 4096 / 1_048_576
                klog("[kworker] heap used=\(usedMiB) MiB free=\(freeMiB) MiB")
            }
            sleep(ticks: 100)               // ~1 s cadence
        }
    }
}

/// First-frame trampoline for fresh threads (reached from thread_start in
/// Scheduler.S, which has already unmasked IRQs). Never returns.
@_cdecl("swift_thread_bootstrap")
func swiftThreadBootstrap() -> Never {
    Scheduler.currentThreadEntry()()
}
