// Preemptive round-robin kernel thread scheduler — SMP version (Pi-5-profile
// 4-core virt: one global run model, per-core scheduling driven by each
// core's own 100 Hz timer tick).
//
// Threads are TCBs in a fixed 16-slot table kept in RAW HEAP MEMORY (one
// page from allocPages, bound to TCB, never reallocated). This is load-
// bearing: the table is read and written from thread context and the timer
// IRQ on EVERY core, so it must stay clear of Swift's shared storage
// machinery — no Swift Array (copy-on-write + subscript access tracking
// across a context switch), and a strictly POD TCB (no String or closure
// fields: their retain/release is not atomic across a preemption boundary
// and corrupts when an IRQ hits mid-access). Entry closures live in a side
// array that is only ever touched in thread context (spawn, reap and first
// start), and task names live only in the Tasks registry (ps).
//
// LOCKING (see Kernel/Locks.swift). All shared scheduler state — the TCB
// table and the per-core arrays — is guarded by Locks.sched, taken with
// Locks.lockIrqSave (spinlock + DAIF mask: atomic against other cores AND
// against this core's timer IRQ). The lock is also held ACROSS the context
// switch itself, baton-style: the thread switching out acquires, the thread
// switched in releases (every arm_switch_context return — including a fresh
// thread's fabricated first "return" into thread_start, which calls
// swift_thread_postswitch — is followed by exactly one unlockIrqRestore).
// Holding the lock across the switch is what makes runningOnCPU claims
// race-free: a slot's stack is provably abandoned before any other core can
// observe the released lock and reclaim it. While holding Locks.sched this
// file never klogs and never allocates; the one legal downward acquisition
// is Locks.tasks (drainTickAccounting -> Tasks.noteRun) — the only
// cross-lock order in the kernel is sched -> tasks, never the reverse.
//
// SMP RUN MODEL. Slot 0 is the boot/main thread, pinned to cpu 0 (the
// compositor, userland apps, virtio drivers and the framebuffer are
// BSP-confined by design). Slot 1 is cpu 0's spawned idle, slot 2 the
// kworker; both may migrate. Slots 3..(2+cpuCount) are RESERVED per-core
// idle slots for secondaries: runCore(cpu:) adopts the secondary's own PSCI
// bring-up stack as that core's idle context (stackBase 0 — no canary) and
// never returns. Every idle slot is pinned to its core, so every core
// always has exactly one always-runnable fallback thread. A slot's
// runningOnCPU field (-1 = not running) is claimed under the sched lock;
// the round-robin pick skips slots running on another core, slots pinned to
// another core, and non-runnable slots.
//
// CONTEXT SWITCH: arm_switch_context (Scheduler.S) pushes the callee-saved
// GPRs x19-x30 and NEON q8-q15 on the current stack, stores the SP into the
// outgoing TCB, loads the incoming TCB's SP, pops the same frame and
// returns. For a fresh thread that "return" lands in thread_start, which
// releases the sched baton (swift_thread_postswitch) and calls
// swift_thread_bootstrap -> the entry closure. A thread preempted from the
// timer IRQ is resumed mid-handler: its switch call returns, it unwinds
// through swift_irq_dispatch back to irq_entry, restores x0-x18/x30 from
// the frame the stub pushed, and erets to exactly where it was interrupted.
//
// PREEMPTION: Interrupts.handleIrq calls Scheduler.onTimerTick AFTER the
// GIC EOI, on every core (each core arms its own CNTP tick via
// Interrupts.initCoreInterrupts). The EOI-first order matters: while the
// timer PPI is still active the GIC will not re-signal it, so a switch that
// deferred EOI until the preempted thread runs again would starve the tick.
// onTimerTick tolerates arriving on a core BEFORE runCore has adopted it
// (coreOnline is still false: the tick is EOI'd and ignored there).
//
// CPU ACCOUNTING reaches ps / System Monitor via drainTickAccounting(),
// which Tasks.foldCpuPercent calls once per frame on the main thread
// (thread context — the IRQ path itself never touches the Tasks registry).
// Percentages are Linux-style per-core (see Tasks.swift): 100% = one full
// core. perCoreUsage() additionally exposes raw per-core busy/total tick
// counters for the System Monitor's per-core bars.
//
// STACK CANARIES: every spawned thread's stack is filled with 0xAA and
// carries a 16-byte canary (two UInt64 magics) at its BASE. AArch64 stacks
// grow down, so an overflow clobbers the base last before running off the
// allocation — the canary is the tripwire. Cpu 0's tick audits every live
// thread's canary every ~100 ms under the sched lock (fixed table walk, two
// loads per slot, no allocation) and panics with the offending thread id on
// the first mismatch; the per-thread panic note is precomputed at spawn so
// the audit never allocates. Slot 0 and the adopted secondary-idle slots
// are NOT audited (their stacks belong to Boot.S / the PSCI bring-up).
//
// THREAD LIFECYCLE: entry closures are () -> Never BY CONSTRUCTION —
// returning is impossible (there is nothing to return to; thread_start
// parks forever), so a thread that wants out calls Scheduler.exit(), which
// marks it zombie and switches away for good. kill(id:) marks ANOTHER
// thread zombie — including one RUNNING on another core: that core's next
// schedule point demotes and switches away from it, and never picks it
// again. A zombie is only reclaimed once runningOnCPU == -1 AND the baton
// has passed (i.e. its stack is provably abandoned); reapZombies() runs in
// idle/kworker/runCore THREAD context on whichever core gets there first —
// never from the IRQ path, since reclaiming frees pages and logs. exit()
// abandons the thread's call stack mid-flight: nothing unwinds, and any
// resources the thread held stay held (POSIX pthread_exit semantics, minus
// cleanup handlers). Boot-thread exit stays a panic; the per-core idle
// slots are unkillable (kill returns false).
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
@_silgen_name("arm_read_mpidr")
private func armReadMpidr() -> UInt

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
    /// Canary audit cadence: every 10 cpu-0 timer ticks = ~100 ms.
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
        var stackBase: UInt = 0         // 0 for adopted contexts (boot/PSCI stacks)
        var stackPages = 0
        var sp: UInt = 0                // saved SP, valid while not running
        var wakeTick: UInt64 = 0
        var ticksRan: UInt64 = 0        // tick count from the timer IRQs
        var accountedTicks: UInt64 = 0  // ticks already drained into Tasks
        var taskID = 0                  // Tasks registry id (ps/System Monitor)
        var runningOnCPU = -1           // core currently executing this slot, else -1
        var pinnedCPU = -1              // -1 = may run anywhere; else only this core
    }

    /// Raw TCB table: one heap page, allocated and bound in initScheduler.
    /// Accessed only through this pointer, under Locks.sched — plain
    /// loads/stores on both the thread and IRQ paths, no Swift container
    /// semantics involved.
    private static var tcbs: UnsafeMutablePointer<TCB>?

    /// Thread entry closures by slot. THREAD CONTEXT ONLY: written by
    /// spawn/reap, read once by swift_thread_bootstrap at a thread's first
    /// start. Never touched from the IRQ path or across a switch boundary.
    private static var entries = [(() -> Never)?](repeating: nil, count: maxThreads)

    /// Per-slot panic note for the canary audit ("stack overflow in
    /// thread N"). Written by spawn/reapZombies in thread context; the
    /// IRQ-side audit only ever READS it, and only on a canary trip —
    /// which is terminal (kpanic), so no allocation happens on the IRQ
    /// path and the read can race with nothing that matters.
    private static var panicNotes = [String](repeating: "", count: maxThreads)

    // MARK: Per-core scheduling state (all sized Config.cpuCount)
    //
    // Plain fixed Arrays, allocated and first-touched on the BSP in
    // initScheduler (no lazy-static first touch from secondaries). Element
    // accesses are lock-free reads/writes of aligned words; cross-core
    // consistency comes from the sched lock on every mutating path.

    /// Slot currently executing on each core.
    private static var currentSlot = [Int](repeating: 0, count: Config.cpuCount)
    /// Ticks the current thread on each core may still run before preemption.
    private static var quantumLeft = [Int](repeating: 0, count: Config.cpuCount)
    /// Round-robin scan cursor per core.
    private static var rrCursor = [Int](repeating: 0, count: Config.cpuCount)
    /// Per-core tick accounting for perCoreUsage(): non-idle / all ticks.
    private static var busyTicks = [UInt64](repeating: 0, count: Config.cpuCount)
    private static var totalTicks = [UInt64](repeating: 0, count: Config.cpuCount)
    /// true once the core schedules (cpu 0 at init; secondaries in runCore).
    private static var coreOnline = [Bool](repeating: false, count: Config.cpuCount)
    /// Each core's idle slot (cpu 0 -> 1; cpu N>0 -> 2+N; -1 when !smpEnabled).
    private static var idleSlotOfCpu = [Int](repeating: -1, count: Config.cpuCount)

    private static var initialized = false
    private static var ticksSinceCanaryCheck = 0
    /// Serial number for demoSpinners names (spin0, spin1, ... across calls).
    private static var spinSerial = 0

    // arm_switch_context frame: see the layout comment in Scheduler.S.
    private static let switchFrameSize = 224
    private static let switchFrameX30Offset = 136

    /// Demo counter bumped by the kworker thread once per second.
    static private(set) var kworkerCounter: UInt64 = 0

    /// True when the scheduler initialized successfully (tick accounting
    /// live). Tasks.foldCpuPercent uses this to pick its %CPU semantics.
    static var isActive: Bool { Config.enableScheduler && initialized }

    /// This core's index (MPIDR_EL1 Aff0 on QEMU virt), clamped defensively.
    @inline(__always)
    private static func thisCpu() -> Int {
        let c = Int(armReadMpidr() & 0xFF)
        return c < Config.cpuCount ? c : 0
    }

    /// Slots reserved as secondary-core idle contexts (3..2+cpuCount).
    private static func isReservedIdleSlot(_ id: Int) -> Bool {
        Config.smpEnabled && id >= 3 && id < 3 &+ (Config.cpuCount &- 1)
    }

    /// Slots that must never be killed: cpu 0's idle (1) and the reserved
    /// per-core idle slots. kill() returns false for these.
    private static func isIdleSlot(_ id: Int) -> Bool {
        id == 1 || isReservedIdleSlot(id)
    }

    // MARK: - Init

    /// Bring up the scheduler: allocate the TCB table, adopt the boot/main
    /// thread as slot 0 (pinned to cpu 0), spawn the idle + kworker threads,
    /// and set up the per-core state secondaries will adopt in runCore.
    /// Call once on the BSP, AFTER Interrupts.initInterrupts and BEFORE
    /// SMP.startSecondaries. No-op unless Config.enableScheduler.
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

        // Warm every lazy static secondaries might touch, here on the BSP:
        // a lazy-global first touch from a secondary is not allowed.
        _ = Locks.sched
        _ = Locks.tasks
        _ = spinSerial

        // Slot 0: the boot/main thread. Pinned to cpu 0 — the compositor,
        // userland apps, virtio drivers and the framebuffer stay there.
        table[0].used = true
        table[0].state = .running
        table[0].runningOnCPU = 0
        table[0].pinnedCPU = 0
        table[0].taskID = Tasks.register(name: "main", memoryMB: 1)

        var c = 0
        while c < Config.cpuCount {
            currentSlot[c] = 0
            quantumLeft[c] = quantumTicks
            rrCursor[c] = 0
            busyTicks[c] = 0
            totalTicks[c] = 0
            coreOnline[c] = (c == 0)
            idleSlotOfCpu[c] = c == 0 ? 1 : (Config.smpEnabled ? 2 &+ c : -1)
            c &+= 1
        }
        initialized = true

        // Slots 1 and 2 (the scan order guarantees this): cpu 0's idle and
        // the kworker. The idle is pinned — every core keeps its own idle
        // as the always-runnable fallback.
        _ = spawn(name: "idle", stackPages: 1, entry: idleMain)
        _ = spawn(name: "kworker", stackPages: 2, entry: kworkerMain)
        table[1].pinnedCPU = 0

        klog("[sched] scheduler up: main + idle + kworker, quantum 50 ms, \(Config.cpuCount) cores")
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
    /// - Two-phase: all allocation (stack pages, Tasks registry) happens
    ///   lock-free in phase A; phase B takes Locks.sched only to scan for a
    ///   free slot and publish it (used is written last). The reserved
    ///   per-core idle slots are skipped by the scan.
    /// - Stack-alloc/registry failure unwinds cleanly to -1 with the
    ///   registry entry removed and the pages freed.
    /// - A zero-length name registers as "thread".
    @discardableResult
    static func spawn(name: String, stackPages: Int, entry: @escaping () -> Never) -> Int {
        guard Config.enableScheduler, initialized, stackPages > 0 else { return -1 }
        guard let tcbs else { return -1 }

        // Phase A (no scheduler lock): stack + canary + initial frame.
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

        // Phase B (under Locks.sched): claim a slot and publish it.
        let saved = Locks.lockIrqSave(Locks.sched)
        var slot = -1
        var i = 1
        while i < maxThreads {
            if !isReservedIdleSlot(i), !tcbs[i].used { slot = i; break }
            i &+= 1
        }
        guard slot >= 0 else {
            Locks.unlockIrqRestore(Locks.sched, saved)
            Tasks.unregister(id: taskID)
            KernelHeap.freePages(base, count: stackPages)
            return -1
        }

        tcbs[slot].state = .runnable
        tcbs[slot].stackBase = base
        tcbs[slot].stackPages = stackPages
        tcbs[slot].sp = sp0
        tcbs[slot].wakeTick = 0
        tcbs[slot].ticksRan = 0
        tcbs[slot].accountedTicks = 0
        tcbs[slot].taskID = taskID
        tcbs[slot].runningOnCPU = -1
        tcbs[slot].pinnedCPU = -1
        entries[slot] = entry               // thread-context side table
        panicNotes[slot] = "stack overflow in thread \(slot)"
        tcbs[slot].used = true              // publish last
        Locks.unlockIrqRestore(Locks.sched, saved)
        return slot
    }

    // MARK: - Cooperative primitives

    /// Voluntarily hand the CPU to the next runnable thread. Safe to call
    /// with IRQs in any state — the entry DAIF is restored on return.
    static func yield() {
        guard Config.enableScheduler, initialized else { return }
        schedulePoint(cpu: thisCpu())
    }

    /// Block the current thread for `ticks` timer ticks (10 ms each):
    /// mark sleeping, switch away, and let the timer IRQ flip the state
    /// back to runnable once the wake tick has passed. The thread may
    /// resume on a different core than the one it slept on.
    static func sleep(ticks: UInt64) {
        guard Config.enableScheduler, initialized, let tcbs else { return }
        let me = currentSlot[thisCpu()]
        let wake = Interrupts.uptimeTicks() &+ ticks
        while true {
            let cpu = thisCpu()             // recomputed: may have migrated
            let saved = Locks.lockIrqSave(Locks.sched)
            if Interrupts.uptimeTicks() >= wake {
                tcbs[me].state = .running
                Locks.unlockIrqRestore(Locks.sched, saved)
                return
            }
            tcbs[me].wakeTick = wake
            tcbs[me].state = .sleeping
            pickAndSwitchLocked(cpu: cpu)
            Locks.unlockIrqRestore(Locks.sched, saved)
        }
    }

    /// Table slot of the thread currently running on THIS core
    /// (0 = boot/main thread).
    static var currentThreadID: Int { currentSlot[thisCpu()] }

    // MARK: - Thread termination (exit / kill / reap)

    /// Terminate the CALLING thread: mark it zombie and switch away for
    /// good. The slot stays allocated until reapZombies() reclaims it from
    /// idle/kworker/runCore thread context. This is the only way out of a
    /// thread — entry closures are () -> Never by construction, so
    /// "returning" is impossible; a thread that is done calls exit().
    /// Abandons the call stack mid-flight: nothing unwinds, held resources
    /// stay held.
    static func exit() -> Never {
        guard Config.enableScheduler, initialized, let tcbs else {
            while true { armWfi() }
        }
        let cpu = thisCpu()
        let me = currentSlot[cpu]
        if me == 0 {
            kpanic("scheduler: boot thread cannot exit")
        }
        let saved = Locks.lockIrqSave(Locks.sched)
        tcbs[me].state = .zombie        // pickAndSwitchLocked only picks .runnable
        pickAndSwitchLocked(cpu: cpu)
        // Unreachable: a zombie is never selected again. If a bug ever
        // lets the switch return, park instead of running dead code.
        Locks.unlockIrqRestore(Locks.sched, saved)
        while true { armWfi() }
    }

    /// Mark ANOTHER thread zombie: it is never scheduled again and the
    /// reaper reclaims its slot. `id` is the ps-shown Tasks-registry id
    /// (resolved to a slot via the TCB taskID field). Refuses the boot
    /// thread, the caller itself (a thread that wants out uses exit()), and
    /// the per-core idle slots by returning false; also false for unknown
    /// or already-zombie ids. Killing a thread that is RUNNING on another
    /// core is legal: it keeps running until that core's next schedule
    /// point (tick quantum, yield or sleep), which demotes it and never
    /// picks it again; the reaper waits for runningOnCPU == -1 before
    /// touching its stack.
    @discardableResult
    static func kill(id: Int) -> Bool {
        guard Config.enableScheduler, initialized, let tcbs else { return false }
        let saved = Locks.lockIrqSave(Locks.sched)
        // Resolve the Tasks-registry id to a live slot.
        var slot = -1
        var i = 1                       // slot 0 (boot thread) is never killable
        while i < maxThreads {
            if tcbs[i].used, tcbs[i].taskID == id { slot = i; break }
            i &+= 1
        }
        if slot >= 0, !isIdleSlot(slot), tcbs[slot].state != .zombie,
           slot != currentSlot[thisCpu()] {
            tcbs[slot].state = .zombie    // the wake scan only revives .sleeping
            tcbs[slot].wakeTick = 0
            Locks.unlockIrqRestore(Locks.sched, saved)
            return true
        }
        Locks.unlockIrqRestore(Locks.sched, saved)
        return false
    }

    /// Reclaim every zombie slot whose stack is provably abandoned: clear
    /// the TCB and side tables, free the stack pages, unregister the task,
    /// and log the reclaim. THREAD CONTEXT ONLY (frees memory, releases
    /// references, klogs) — called from the idle, kworker and runCore idle
    /// loops on any core, never from the IRQ path. Multiple reapers may run
    /// concurrently on different cores: the claim (used+zombie+not-running
    /// -> cleared slot) happens in one sched-lock section, so exactly one
    /// reaper wins each zombie, and spawn/canary/accounting scans never
    /// observe a half-torn-down slot. The stack free happens AFTER the slot
    /// stops being visible, so the canary audit can never read freed pages.
    private static func reapZombies() {
        guard Config.enableScheduler, initialized, let tcbs else { return }
        var i = 1                       // slot 0 (boot thread) can never be a zombie
        while i < maxThreads {
            var base: UInt = 0
            var pages = 0
            var taskID = 0
            var found = false
            let saved = Locks.lockIrqSave(Locks.sched)
            if tcbs[i].used, tcbs[i].state == .zombie, tcbs[i].runningOnCPU == -1 {
                // runningOnCPU == -1 here means the baton has passed since
                // the thread last ran: its stack is abandoned (the core
                // that switched away from it held this lock across the
                // switch, so acquiring the lock proves the switch finished).
                found = true
                base = tcbs[i].stackBase
                pages = tcbs[i].stackPages
                taskID = tcbs[i].taskID
                entries[i] = nil
                panicNotes[i] = ""
                tcbs[i] = TCB()         // whole-slot reset, published atomically
            }
            Locks.unlockIrqRestore(Locks.sched, saved)
            if found {
                if base != 0 {
                    KernelHeap.freePages(base, count: pages)
                }
                Tasks.unregister(id: taskID)
                klog("[sched] reaped thread \(i) (task \(taskID)) — slot free")
            }
            i &+= 1
        }
    }

    // MARK: - Timer IRQ hook (IRQ CONTEXT: counters + fixed-table writes only)

    /// Called from Interrupts.handleIrq on every core's timer tick, after
    /// the GIC EOI. Accounts one tick to the thread current on THIS core
    /// (and to the core's busy/total counters), wakes due sleepers, audits
    /// stack canaries on cpu 0 every ~100 ms, and preempts round-robin
    /// every quantumTicks. Takes Locks.sched via lockIrqSave — legal in
    /// IRQ context because every holder holds it with IRQs masked, so a
    /// tick can never self-deadlock on its own core; the critical sections
    /// are allocation-free 16-slot scans.
    static func onTimerTick() {
        guard Config.enableScheduler, initialized, let tcbs else { return }
        let cpu = thisCpu()
        guard coreOnline[cpu] else { return }   // tick before runCore adoption

        let saved = Locks.lockIrqSave(Locks.sched)

        // Per-core accounting: bill the slot current on THIS cpu.
        totalTicks[cpu] &+= 1
        let cur = currentSlot[cpu]
        if tcbs[cur].used {
            tcbs[cur].ticksRan &+= 1
            if cur != idleSlotOfCpu[cpu] { busyTicks[cpu] &+= 1 }
        }

        // Wake due sleepers (every core scans; idempotent under the lock).
        let now = Interrupts.uptimeTicks()
        var i = 0
        while i < maxThreads {
            if tcbs[i].used, tcbs[i].state == .sleeping, now >= tcbs[i].wakeTick {
                tcbs[i].state = .runnable
            }
            i &+= 1
        }

        // Canary audit on cpu 0 only: the stacks are core-independent, one
        // auditor is enough, and it keeps the (terminal) panic path singular.
        if cpu == 0 {
            ticksSinceCanaryCheck &+= 1
            if ticksSinceCanaryCheck >= canaryCheckIntervalTicks {
                ticksSinceCanaryCheck = 0
                checkStackCanaries()
            }
        }

        // This core's quantum countdown; on expiry run a schedule point.
        quantumLeft[cpu] &-= 1
        if quantumLeft[cpu] <= 0 {
            quantumLeft[cpu] = quantumTicks
            pickAndSwitchLocked(cpu: cpu)
        }
        Locks.unlockIrqRestore(Locks.sched, saved)
    }

    /// IRQ-side stack-canary audit: verify the 16-byte canary at the base
    /// of every live spawned thread's stack. A mismatch means the thread
    /// already ran past its stack — fatal, panic immediately. No
    /// allocation: the message is precomputed per slot at spawn. Slots with
    /// stackBase 0 (boot thread, adopted secondary idles) are skipped;
    /// zombie slots still hold their stacks until reaped and stay audited.
    /// Called with Locks.sched held.
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
    /// caller can keep a fallback denominator. Takes Locks.sched; the
    /// nested Tasks.noteRun (Locks.tasks) is the kernel's only cross-lock
    /// order, sched -> tasks, and is never inverted.
    static func drainTickAccounting() -> UInt64 {
        guard Config.enableScheduler, initialized, let tcbs else { return 0 }
        var total: UInt64 = 0
        let saved = Locks.lockIrqSave(Locks.sched)
        var i = 0
        while i < maxThreads {
            if tcbs[i].used {
                let ran = tcbs[i].ticksRan
                let d = ran &- tcbs[i].accountedTicks
                if d > 0 {
                    tcbs[i].accountedTicks = ran
                    Tasks.noteRun(id: tcbs[i].taskID, ticks: d)
                    total &+= d
                }
            }
            i &+= 1
        }
        Locks.unlockIrqRestore(Locks.sched, saved)
        return total
    }

    /// Raw per-core tick counters (busy = non-idle) since each core came
    /// online, one tuple per core, indexed by cpu. Snapshot for the System
    /// Monitor's per-core bars; the caller differences successive snapshots.
    /// Thread context only (allocates the result array).
    static func perCoreUsage() -> [(busy: UInt64, total: UInt64)] {
        var out: [(busy: UInt64, total: UInt64)] = []
        guard Config.enableScheduler, initialized else { return out }
        out.reserveCapacity(Config.cpuCount)
        var c = 0
        while c < Config.cpuCount {
            // Aligned UInt64 loads: tear-free against the cores' tick IRQs.
            out.append((busy: busyTicks[c], total: totalTicks[c]))
            c &+= 1
        }
        return out
    }

    /// Entry closure of the thread running on THIS core, for
    /// swift_thread_bootstrap. Thread context (first start only).
    static func currentThreadEntry() -> () -> Never {
        if let entry = entries[currentSlot[thisCpu()]] {
            return entry
        }
        kpanic("scheduler: running thread has no entry")
    }

    // MARK: - Demo workload (SMP visibility: ps / top / System Monitor)

    /// Spawn `count` compute threads ("spin<N>") that burn CPU with light
    /// allocation churn — a small local Array grown to 64 elements and
    /// cleared without keeping capacity, so every cycle frees and
    /// re-allocates through the cross-core heap lock — yielding about once
    /// per timer tick (10 ms; the finest tick-math cadence available) so
    /// other threads on the same core get in. The pick logic spreads them
    /// across the cores. Returns the number actually spawned (less than
    /// `count` when the thread table is nearly full). They run until
    /// kill(id:) or exit; reaping is automatic.
    @discardableResult
    static func demoSpinners(count: Int) -> Int {
        guard Config.enableScheduler, initialized, count > 0 else { return 0 }
        var spawned = 0
        while spawned < count {
            let serial = spinSerial
            spinSerial &+= 1
            if spawn(name: "spin\(serial)", stackPages: 1, entry: spinnerMain) < 0 {
                break
            }
            spawned &+= 1
        }
        return spawned
    }

    /// Compute-thread body for demoSpinners: churn the heap, yield roughly
    /// once per tick, run forever (until killed).
    private static func spinnerMain() -> Never {
        var churn: [UInt64] = []
        var lastTick = Interrupts.uptimeTicks()
        while true {
            if churn.count < 64 {
                churn.append(UInt64(churn.count) &* 0x9E37_79B9)
            } else {
                churn.removeAll(keepingCapacity: false)   // free the buffer
            }
            let now = Interrupts.uptimeTicks()
            if now != lastTick {
                lastTick = now
                Scheduler.yield()
            }
        }
    }

    // MARK: - Secondary-core entry

    /// Secondary cores' entry into scheduling (called by the SMP bring-up
    /// flow at EL1, after Interrupts.initCoreInterrupts, with the core's
    /// own 100 Hz tick live). Adopts this context — the per-core PSCI
    /// bring-up stack — as the core's pinned idle slot and NEVER returns.
    /// The loop: reclaim zombies (reaping runs on whichever core gets
    /// there), pick the next runnable slot (round-robin from this core's
    /// cursor, skipping slots running on another core or pinned elsewhere),
    /// switch in with a fresh local quantum; when nothing else is runnable
    /// the pick keeps the idle context and wfi parks the core until its
    /// next local tick.
    static func runCore(cpu: Int) -> Never {
        guard Config.enableScheduler, Config.smpEnabled, initialized, let tcbs,
              cpu > 0, cpu < Config.cpuCount, 2 &+ cpu < maxThreads else {
            while true { armWfi() }
        }
        let slot = 2 &+ cpu
        let taskID = Tasks.register(name: "idle\(cpu)", memoryMB: 0)

        let saved = Locks.lockIrqSave(Locks.sched)
        tcbs[slot].used = true
        tcbs[slot].state = .running
        tcbs[slot].runningOnCPU = cpu
        tcbs[slot].pinnedCPU = cpu
        tcbs[slot].taskID = taskID
        currentSlot[cpu] = slot
        rrCursor[cpu] = slot
        quantumLeft[cpu] = quantumTicks
        coreOnline[cpu] = true
        Locks.unlockIrqRestore(Locks.sched, saved)

        klog("[sched] cpu \(cpu) online: idle slot \(slot), local tick 100 Hz")

        while true {
            reapZombies()
            schedulePoint(cpu: cpu)
            armWfi()
        }
    }

    // MARK: - Round-robin switch

    /// One schedule point on this core: take Locks.sched, switch to the
    /// next runnable slot if there is one, release the lock. The unlock
    /// runs both when nothing switched and when THIS thread is later
    /// resumed — the lock is held across arm_switch_context baton-style
    /// (see the file header), so the resume-side unlock is what releases
    /// the previous holder's acquisition.
    private static func schedulePoint(cpu: Int) {
        let saved = Locks.lockIrqSave(Locks.sched)
        pickAndSwitchLocked(cpu: cpu)
        Locks.unlockIrqRestore(Locks.sched, saved)
    }

    /// Switch this core to the next runnable slot after its cursor. Two
    /// passes: real (non-idle) threads first — a runnable, unclaimed
    /// (runningOnCPU == -1), correctly-pinned slot, round-robin from this
    /// core's cursor; if no real thread wants the core, the CURRENT thread
    /// keeps it (idle never displaces working code), and only a departing
    /// current thread (sleeping/zombie) is replaced by this core's pinned
    /// idle. This makes the per-core idles true fallbacks: they burn the
    /// core only when nothing else can, instead of taking an equal
    /// round-robin share. REQUIRES Locks.sched held (via lockIrqSave). The
    /// lock stays held across arm_switch_context and is released by
    /// whichever thread runs next on this core (its own post-switch
    /// unlockIrqRestore, or swift_thread_postswitch on a first start). No
    /// allocation; raw table loads/stores only. A .zombie prev stays
    /// zombie — only a .running prev is demoted back to .runnable.
    private static func pickAndSwitchLocked(cpu: Int) {
        guard let tcbs else { return }
        let prev = currentSlot[cpu]
        var next = -1
        var step = 1
        while step < maxThreads {
            let cand = (rrCursor[cpu] &+ step) % maxThreads
            if tcbs[cand].used, tcbs[cand].state == .runnable,
               tcbs[cand].runningOnCPU == -1,
               tcbs[cand].pinnedCPU == -1 || tcbs[cand].pinnedCPU == cpu,
               !isIdleSlot(cand) {
                next = cand
                break
            }
            step &+= 1
        }
        if next < 0 {
            // No real thread wants this core right now.
            if tcbs[prev].state == .running { return }   // prev keeps the core
            let idle = idleSlotOfCpu[cpu]
            guard idle >= 0, idle != prev, tcbs[idle].used,
                  tcbs[idle].state == .runnable,
                  tcbs[idle].runningOnCPU == -1 else { return }
            next = idle
        }
        guard next != prev else { return }
        if tcbs[prev].state == .running { tcbs[prev].state = .runnable }
        tcbs[prev].runningOnCPU = -1
        tcbs[next].state = .running
        tcbs[next].runningOnCPU = cpu
        currentSlot[cpu] = next
        rrCursor[cpu] = next
        quantumLeft[cpu] = quantumTicks
        let newSP = tcbs[next].sp
        armSwitchContext(&tcbs[prev].sp, newSP)
        // Returns here when THIS thread is picked again on some core; the
        // caller's unlockIrqRestore then releases the sched-lock baton.
    }

    // MARK: - Built-in threads

    /// Idle thread (cpu 0): reclaim zombie slots, then park in wfi. Never
    /// sleeps in scheduler terms and is pinned to cpu 0, so cpu 0 always
    /// has at least one runnable thread. With the two-pass pick it is a
    /// true fallback: it runs only when no real thread wants cpu 0 —
    /// routine reaping is carried by the (unpinned, non-idle) kworker and
    /// the secondary idles.
    private static func idleMain() -> Never {
        while true {
            reapZombies()
            armWfi()
        }
    }

    /// Kernel worker: the guaranteed reaper (the idle threads are fallback-
    /// only now, so a busy machine may never run them), the demo
    /// once-a-second counter, and the heap health loop —
    /// KernelHeap.validate() every ~10 s (a failure is logged exactly once,
    /// then the latch silences repeats) and a one-line heap stat every
    /// ~60 s. Not pinned: may run on any core.
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

/// Fresh-thread prologue (reached from thread_start in Scheduler.S before
/// swift_thread_bootstrap): a thread's first switch-in inherits the
/// sched-lock baton from the core that switched to it — release it here.
/// DAIF 0 also unmasks IRQs (fresh threads start with IRQs enabled, as the
/// old `daifclr #2` did). Never allocates.
@_cdecl("swift_thread_postswitch")
func swiftThreadPostswitch() {
    Locks.unlockIrqRestore(Locks.sched, 0)
}

/// First-frame trampoline for fresh threads (reached from thread_start in
/// Scheduler.S, after swift_thread_postswitch). Never returns.
@_cdecl("swift_thread_bootstrap")
func swiftThreadBootstrap() -> Never {
    Scheduler.currentThreadEntry()()
}
