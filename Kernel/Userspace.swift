// ============================================================================
// EL0 userspace — two ways to run unprivileged code, sharing one SVC ABI
// and one crash guard:
//
// 1. LEGACY SYNCHRONOUS DEMO (runDemo): a run is a synchronous round trip
//    on the calling (main) thread: arm_run_el0 (Kernel/Userspace.S) stashes
//    the kernel SP in a global, erets into EL0t (IRQs unmasked) at the blob
//    entry with a private stack, and the only way back is the teardown path
//    in sync_lower_entry (Kernel/Vectors.S): the exit syscall (or a user
//    fault) reloads the stashed SP and jumps into arm_run_el0's epilogue,
//    so from Swift's perspective armRunEl0 simply returns a marker. The
//    blob runs identity-mapped in two shared heap pages EL0-marked by
//    MMU.allowEL0. Unchanged from round 2 — including its 30 ms runtime.
//
// 2. SCHEDULED USER PROCESSES (spawn/kill): spawn() loads the blob into a
//    fresh per-process EL0 window and creates a NORMAL SCHEDULER THREAD
//    (round-robin, 50 ms quantum, migratable, visible in ps/top as
//    user<N>) whose entry drops to EL0 via arm_drop_el0 and NEVER comes
//    back: the exit syscall and user faults are terminal via
//    Scheduler.exit() in the sync handler (the whole kernel stack is
//    abandoned and reaped, POSIX pthread_exit style), and a kill() from
//    another core marks the thread zombie — its core's next schedule
//    point demotes it, and the reaper frees the kernel stack, the EL0
//    pages and the page tables. While at EL0 the thread is fully
//    preemptible: timer IRQs take the lower-EL IRQ vector row into
//    irq_entry, and the scheduler can switch away (and migrate) it exactly
//    like a kernel thread.
//
//    Memory (per process, one allocPages(4) call): blob page, stack page,
//    L2 table page, L3 table page. The L2/L3 pair is the process's PRIVATE
//    user map (MMU.makeUserMap): it maps exactly the blob page (EL0+EL1
//    RW, PXN, executable at EL0) and the stack page (+UXN) at
//    MMU.userWinBase — the same VAs for every process, which is safe
//    because each core's private L1 (MMU perCoreL0/perCoreL1) points its
//    L1[userSlot] at the map of the user process running on THAT core
//    only. The scheduler's switch hook installs/clears it on every switch
//    (with a local TLB flush), so two processes can be at EL0
//    SIMULTANEOUSLY on two cores and a migrating process always lands on
//    its own pages. Every VA outside the two pages is invalid at EL0 —
//    an access faults and is contained as a user fault (never a panic).
//
//    Output: write(fd 1) bytes are appended to the process's capture
//    buffer (drainable from the shell via drainOutput) and mirrored live
//    to the UART, so progress shows on the serial console.
//
// ================================= SYSCALL ABI =============================
// svc #0, syscall number in x8, args in x0-x5, result in x0. Unknown
// numbers return -1 (0xFFFF_FFFF_FFFF_FFFF) in x0. Vector registers are
// NOT preserved across an svc (only x19-x29 survive, via the AAPCS
// callee-saved guarantee) — keep the blob integer-only.
//   0  write(fd=x0, buf=x1, len=x2) -> x0 = bytes written, or -1 on a bad
//      fd (only fd 1 exists) or a buf range outside the run's own user
//      pages. Legacy runs capture into a per-run buffer runDemo() returns;
//      scheduled processes capture per-process (drainOutput) + UART mirror.
//      Capped at captureLimit; writes past the cap are short writes.
//   1  uptime_ms() -> x0 = Clock.uptimeMs.
//   2  exit(code=x0) — ends the run; never returns to the blob.
//   3  yield() -> x0 = 0. Scheduler.yield() from the exception handler.
//
// Blob arguments (x0/x1 at entry): x0 = run mode (0 = legacy short demo,
// 1 = scheduled long run), x1 = process serial N (scheduled runs only).
//
// User crash guard: any non-SVC synchronous exception from EL0 (undefined
// instruction, data/instruction abort, …) kills just the run instead of
// the kernel: runDemo returns "<udemo>: user program faulted (ESR=…,
// ELR=…)", a scheduled process is logged ("[user] user<N> … faulted") and
// terminated via Scheduler.exit(). A lower-EL sync exception with no
// active run and no current user thread is still a kernel panic — it
// cannot happen unless something is already badly wrong.
// ============================================================================

@_silgen_name("arm_run_el0")
private func armRunEl0(_ entry: UInt, _ userSP: UInt) -> UInt64
@_silgen_name("arm_drop_el0")
private func armDropEl0(_ entry: UInt, _ userSP: UInt, _ mode: UInt, _ serial: UInt) -> Never
@_silgen_name("arm_read_far_el1")
private func armReadFarEl1() -> UInt64

enum UserProcess {
    /// Pinned integration API: Userland/Shell.swift's `udemo` command calls
    /// this and prints the result like any command output.
    static func runDemo() -> String {
        guard Config.enableUserland else { return "udemo: userspace disabled" }
        return runBlob(UserBlob.bytes)
    }

    // MARK: - Scheduled user processes (pinned API: spawn / kill)

    /// Pinned integration API: Userland/Shell.swift's `urun` command.
    /// Load `blob` into a fresh per-process EL0 window and schedule it as a
    /// normal preemptible kernel thread (user<N> in ps/top) that runs at
    /// EL0 until it exits, faults or is killed. Returns the Tasks-registry
    /// pid (>= 0), or -1 on failure: userspace or scheduler disabled, MMU
    /// off (the user-window VAs only exist through per-process maps), a
    /// bad/oversized blob, the process table full, or out of pages/threads.
    static func spawn(blob: [UInt8]) -> Int {
        guard Config.enableUserland, Config.enableScheduler,
              Scheduler.isActive, MMU.isOn else { return -1 }
        guard !blob.isEmpty, blob.count <= 4096 else { return -1 }

        // Claim a process-table slot (spawn can run on any core's thread
        // context — the shell on cpu 0, kernel probes elsewhere).
        var saved = Locks.lockIrqSave(Locks.tasks)
        var slot = -1
        var i = 0
        while i < maxProcs {
            if !procs[i].used { slot = i; break }
            i &+= 1
        }
        var serial = 0
        if slot >= 0 {
            userSerial &+= 1
            serial = userSerial
            procs[slot].used = true          // claim; fields published below
            procs[slot].serial = serial
        }
        Locks.unlockIrqRestore(Locks.tasks, saved)
        guard slot >= 0 else { return -1 }

        // Four contiguous pages: blob, stack, L2, L3. One allocation, one
        // free at reap; the whole range is zeroed (blob page tail, stack
        // and both tables all want zeros), then the blob is copied in and
        // the private user map is built.
        guard let pages = KernelHeap.allocPages(4) else {
            releaseProc(slot)
            return -1
        }
        var p = pages
        while p < pages &+ 16384 {
            UnsafeMutablePointer<UInt64>(bitPattern: p)!.pointee = 0
            p &+= 8
        }
        i = 0
        while i < blob.count {
            UnsafeMutableRawPointer(bitPattern: pages)!
                .storeBytes(of: blob[i], toByteOffset: i, as: UInt8.self)
            i &+= 1
        }
        let l2 = pages &+ 8192
        let l3 = pages &+ 12288
        MMU.makeUserMap(l2: l2, l3: l3, blobPA: pages, stackPA: pages &+ 4096)

        // Publish the fields the SVC handler needs BEFORE the thread can
        // run anywhere (the pid is published after the scheduler spawn —
        // it is only used for kill/drainOutput lookups, which can only
        // happen once spawn() has returned it).
        saved = Locks.lockIrqSave(Locks.tasks)
        procs[slot].pages = pages
        procs[slot].l2 = l2
        procs[slot].capture.reserveCapacity(256)
        Locks.unlockIrqRestore(Locks.tasks, saved)

        let thread = Scheduler.spawn(name: "user\(serial)", stackPages: 1,
                                     userProc: slot, userL2: l2,
                                     userSP: MMU.userWinBase &+ MMU.userWinSpan,
                                     entry: { UserProcess.userThreadMain(serial: serial) })
        guard thread >= 0 else {
            releaseProc(slot)
            KernelHeap.freePages(pages, count: 4)
            return -1
        }
        let pid = Scheduler.taskID(ofSlot: thread)
        saved = Locks.lockIrqSave(Locks.tasks)
        procs[slot].pid = pid
        Locks.unlockIrqRestore(Locks.tasks, saved)
        klog("[user] user\(serial) spawned: pid \(pid), blob \(blob.count) bytes, thread slot \(thread)")
        return pid
    }

    /// Pinned integration API: Userland/Shell.swift's `ukill` command.
    /// Terminate the user process with Tasks-registry id `pid`: its thread
    /// is marked zombie — one RUNNING on another core keeps going until
    /// that core's next schedule point (<= one 50 ms quantum), which
    /// demotes it and uninstalls its map — and the reaper then frees the
    /// kernel stack, the EL0 pages and the L2/L3 tables. False for unknown
    /// or non-user pids.
    static func kill(pid: Int) -> Bool {
        guard Config.enableUserland else { return false }
        let saved = Locks.lockIrqSave(Locks.tasks)
        var found = false
        var i = 0
        while i < maxProcs {
            if procs[i].used, procs[i].pid == pid { found = true; break }
            i &+= 1
        }
        Locks.unlockIrqRestore(Locks.tasks, saved)
        guard found else { return false }
        return Scheduler.kill(id: pid)
    }

    /// Additive helper for the shell/terminal: atomically take and clear
    /// the captured stdout of user process `pid` ("" for unknown pids or
    /// no new output). The bytes are also mirrored live to the UART as
    /// they arrive, so serial sessions see progress without draining.
    static func drainOutput(pid: Int) -> String {
        guard Config.enableUserland else { return "" }
        var out: [UInt8] = []
        let saved = Locks.lockIrqSave(Locks.tasks)
        var i = 0
        while i < maxProcs {
            if procs[i].used, procs[i].pid == pid {
                out = procs[i].capture
                procs[i].capture = []
                procs[i].capture.reserveCapacity(256)
                break
            }
            i &+= 1
        }
        Locks.unlockIrqRestore(Locks.tasks, saved)
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: - Process table

    /// Hard cap on live scheduled user processes (the scheduler has 16
    /// slots, 6 of them spoken for — main, two cpu-0 threads, three
    /// secondary idles — so 8 can never be reached through the thread
    /// table anyway; spawn fails there first).
    private static let maxProcs = 8

    /// One scheduled user process. Guarded by Locks.tasks (rung 1; the
    /// table is thread-context only — the SVC handler runs on the owning
    /// thread, spawn/kill/drain on callers' threads, reap on a reaper
    /// thread). `serial`, `pages` and `l2` are immutable once published
    /// (before the thread exists), so the handler reads them lock-free.
    private struct Proc {
        var used = false
        var pid = 0                 // Tasks-registry id (ps/top), == Scheduler taskID
        var serial = 0              // user<N>'s N
        var pages: UInt = 0         // 4 contiguous pages: blob, stack, L2, L3
        var l2: UInt = 0            // == pages + 8 KiB; the thread's TCB userL2
        var capture: [UInt8] = []   // stdout so far (drained by drainOutput)
        var exited = false
        var exitCode: UInt64 = 0
        var firstOutputLogged = false
    }

    private static var procs = [Proc](repeating: Proc(), count: maxProcs)
    private static var userSerial = 0

    /// Warm every lazy static a secondary core could touch first (SMP
    /// rule: no lazy-static first touch from secondaries). Called once
    /// from Scheduler.initScheduler on the BSP.
    static func warmStatics() {
        _ = procs.count
        _ = userSerial
        _ = MMU.userWinBase
        _ = MMU.userWinSpan
        _ = MMU.userSlot
    }

    /// Thread body of every scheduled user process: drop to EL0 at the
    /// user window's blob entry with the window stack top, passing the
    /// long-run mode and the serial. NEVER returns — the exit syscall and
    /// faults are terminal via Scheduler.exit() in the sync handler; timer
    /// preemption and migration resume at EL0 by eret.
    private static func userThreadMain(serial: Int) -> Never {
        armDropEl0(MMU.userWinBase, MMU.userWinBase &+ MMU.userWinSpan,
                   1, UInt(serial))
    }

    /// Free a reaped user thread's process resources (called from
    /// Scheduler.reapZombies, thread context, no locks held). By the time
    /// a thread is reaped its map is installed NOWHERE (the switch hook
    /// replaced it on every core that ever ran the thread, flushing those
    /// TLBs), so freeing the pages is unobservable through translations.
    static func reapProcess(_ proc: Int) {
        guard proc >= 0, proc < maxProcs else { return }
        let saved = Locks.lockIrqSave(Locks.tasks)
        guard procs[proc].used else {
            Locks.unlockIrqRestore(Locks.tasks, saved)
            return
        }
        let pages = procs[proc].pages
        let pid = procs[proc].pid
        let serial = procs[proc].serial
        procs[proc] = Proc()        // also releases the capture buffer
        Locks.unlockIrqRestore(Locks.tasks, saved)
        if pages != 0 {
            KernelHeap.freePages(pages, count: 4)
        }
        klog("[user] user\(serial) (pid \(pid)) reaped — EL0 pages + map freed")
    }

    /// Undo a failed spawn's slot claim (no thread ever saw it).
    private static func releaseProc(_ slot: Int) {
        let saved = Locks.lockIrqSave(Locks.tasks)
        procs[slot] = Proc()
        Locks.unlockIrqRestore(Locks.tasks, saved)
    }

    // MARK: - Legacy run state (runDemo)

    /// Byte span of the user mapping: blob page + stack page.
    private static let userSpan: UInt = 8192
    /// Cap on captured stdout per run.
    private static let captureLimit = 4096

    private static var userBase: UInt = 0        // first of the 2 user pages
    private static var stackTop: UInt = 0
    private static var pagesReady = false
    private static var runActive = false         // reentrancy + handler gate
    private static var capture: [UInt8] = []
    private static var faulted = false
    private static var faultESR: UInt64 = 0
    private static var faultELR: UInt64 = 0
    private(set) static var lastExitCode: UInt64 = 0

    // MARK: - Legacy loader / runner (runDemo)

    /// Load `blob` into the user pages and execute it at EL0 until it exits
    /// or faults. Returns the blob's captured stdout, or an angle-bracketed
    /// diagnostic string on failure.
    private static func runBlob(_ blob: [UInt8]) -> String {
        if runActive { return "<udemo>: a user run is already active" }
        if blob.isEmpty || blob.count > 4096 { return "<udemo>: bad blob" }
        if !pagesReady {
            guard let base = KernelHeap.allocPages(2) else {
                return "<udemo>: could not allocate user pages"
            }
            userBase = base
            stackTop = base &+ userSpan
            MMU.allowEL0(base: base, byteCount: userSpan)
            pagesReady = true
        }

        // Fresh state for every run: zeroed pages, copied blob, empty
        // capture buffer.
        var p = userBase
        while p < userBase &+ userSpan {
            UnsafeMutablePointer<UInt64>(bitPattern: p)!.pointee = 0
            p &+= 8
        }
        var i = 0
        while i < blob.count {
            UnsafeMutableRawPointer(bitPattern: userBase)!
                .storeBytes(of: blob[i], toByteOffset: i, as: UInt8.self)
            i &+= 1
        }
        capture.removeAll(keepingCapacity: true)
        capture.reserveCapacity(1024)
        faulted = false
        faultESR = 0
        faultELR = 0
        lastExitCode = 0

        runActive = true
        let marker = armRunEl0(userBase, stackTop)
        runActive = false

        if faulted {
            return "<udemo>: user program faulted (ESR=" + hex(faultESR)
                + ", ELR=" + hex(faultELR) + ")"
        }
        if marker != 1 {
            // Only markers 1 (exit) and 2 (fault) exist; 2 sets faulted.
            return "<udemo>: user run ended unexpectedly (marker=\(marker))"
        }
        return String(decoding: capture, as: UTF8.self)
    }

    // MARK: - Sync-from-EL0 dispatch (Vectors.S sync_lower_entry)

    /// Handle a synchronous exception from EL0. The frame pointer is the
    /// 176-byte Vectors.S frame as UnsafeMutablePointer<UInt64>:
    ///   [0...18] = x0...x18   [19] = x30   [20] = SPSR_EL1   [21] = ELR_EL1
    /// Returns 0 = resume EL0 (frame may be updated), 1 = user exited,
    /// 2 = user faulted (both tear the legacy run down via el0_kernel_save).
    ///
    /// Dispatch: if the CURRENT thread is a scheduled user thread the
    /// exception belongs to it (handleScheduledSync — exit/fault terminate
    /// the thread via Scheduler.exit() and never return, so the teardown
    /// markers 1/2 remain exclusive to the legacy main-thread demo);
    /// otherwise the legacy runDemo path applies.
    ///
    /// NOTE — no ELR fixup on SVC: on AArch64, SVC entry already sets
    /// ELR_EL1 to the instruction AFTER the svc (verified against QEMU's
    /// -d int trace and Linux's el0_svc, which never adjusts the PC).
    /// "Advancing ELR past the svc" here would skip the next user
    /// instruction. Aborts/undefined instructions instead report ELR = the
    /// faulting instruction itself — exactly what the fault path wants.
    static func handleSyncFromEL0(esr: UInt64, frame: UnsafeMutablePointer<UInt64>) -> UInt64 {
        let proc = Scheduler.currentUserProc
        if proc >= 0 {
            handleScheduledSync(proc: proc, esr: esr, frame: frame)
            return 0
        }
        guard runActive else {
            kpanic("lower-EL sync exception with no active user run")
        }
        // ESR_EL1.EC (bits 31:26): 0x15 = SVC from AArch64.
        guard (esr >> 26) & 0x3F == 0x15 else {
            faulted = true
            faultESR = esr
            faultELR = frame[21]
            return 2
        }
        switch frame[8] {
        case 0:     // write(fd, buf, len)
            frame[0] = doWrite(fd: frame[0], buf: frame[1], len: frame[2])
        case 1:     // uptime_ms()
            frame[0] = Clock.uptimeMs
        case 2:     // exit(code)
            lastExitCode = frame[0]
            return 1
        case 3:     // yield()
            Scheduler.yield()
            frame[0] = 0
        default:    // unknown syscall: -ENOSYS
            frame[0] = UInt64.max
        }
        return 0
    }

    // MARK: - Scheduled-process syscall service

    /// SVC/fault service for a scheduled user thread (runs on the user
    /// thread itself, exception context, IRQs masked). Resumable syscalls
    /// update the frame and fall through to the caller's `return 0`;
    /// exit() and faults are terminal via Scheduler.exit() — the whole
    /// kernel stack (sync frame included) is abandoned and reaped, exactly
    /// like a kernel thread that calls Scheduler.exit() mid-flight.
    private static func handleScheduledSync(proc: Int, esr: UInt64,
                                            frame: UnsafeMutablePointer<UInt64>) {
        // ESR_EL1.EC (bits 31:26): 0x15 = SVC from AArch64. Anything else
        // is a user fault: logged and contained by killing the process —
        // never a kernel panic.
        guard (esr >> 26) & 0x3F == 0x15 else {
            klog("[user] user\(procs[proc].serial) (pid \(procs[proc].pid)): user program faulted"
                + " (ESR=" + hex(esr) + ", ELR=" + hex(frame[21])
                + ", FAR=" + hex(armReadFarEl1()) + ") — killed")
            Scheduler.exit()
        }
        switch frame[8] {
        case 0:     // write(fd, buf, len)
            frame[0] = doProcWrite(proc: proc, fd: frame[0], buf: frame[1], len: frame[2])
            // One-time placement line: which core the process runs on.
            let saved0 = Locks.lockIrqSave(Locks.tasks)
            let first = !procs[proc].firstOutputLogged
            if first { procs[proc].firstOutputLogged = true }
            Locks.unlockIrqRestore(Locks.tasks, saved0)
            if first {
                klog("[user] user\(procs[proc].serial) (pid \(procs[proc].pid)) producing output on cpu \(Scheduler.currentCpu)")
            }
        case 1:     // uptime_ms()
            frame[0] = Clock.uptimeMs
        case 2:     // exit(code)
            let saved = Locks.lockIrqSave(Locks.tasks)
            if procs[proc].used {
                procs[proc].exited = true
                procs[proc].exitCode = frame[0]
            }
            let serial = procs[proc].serial
            let pid = procs[proc].pid
            Locks.unlockIrqRestore(Locks.tasks, saved)
            klog("[user] user\(serial) (pid \(pid)) exited on cpu \(Scheduler.currentCpu), code \(frame[0])")
            Scheduler.exit()
        case 3:     // yield()
            frame[0] = 0
            Scheduler.yield()       // may switch + migrate; the map hook re-arms EL0
        default:    // unknown syscall: -ENOSYS
            frame[0] = UInt64.max
        }
    }

    /// write for a scheduled process: fd 1 only; buf must lie inside the
    /// process's two-page user window [userWinBase, +userWinSpan). Bytes
    /// are read through the identity map (window VA -> the process's own
    /// pages; the range check keeps the kernel inside them), appended to
    /// the process's capture buffer (drainOutput), and mirrored live to
    /// the UART under the klog lock so they can't garble klog lines.
    private static func doProcWrite(proc: Int, fd: UInt64, buf: UInt64, len: UInt64) -> UInt64 {
        guard fd == 1 else { return UInt64.max }
        let win = UInt64(MMU.userWinBase)
        guard buf >= win, len <= UInt64(MMU.userWinSpan),
              buf + len <= win + UInt64(MMU.userWinSpan) else { return UInt64.max }
        let pages = procs[proc].pages               // immutable post-publish
        guard pages != 0 else { return UInt64.max }
        let base = pages &+ UInt(buf - win)         // identity PA of buf

        let saved = Locks.lockIrqSave(Locks.tasks)
        var room = captureLimit - procs[proc].capture.count
        if room < 0 { room = 0 }
        let n = min(Int(len), room)
        var i = 0
        while i < n {
            procs[proc].capture.append(
                UnsafeRawPointer(bitPattern: base &+ UInt(i))!.load(as: UInt8.self))
            i &+= 1
        }
        Locks.unlockIrqRestore(Locks.tasks, saved)

        if n > 0 {
            let lock = armKlogLockAddr()
            armSpinLock(lock)
            var j = 0
            while j < n {
                UART.putc(UnsafeRawPointer(bitPattern: base &+ UInt(j))!.load(as: UInt8.self))
                j &+= 1
            }
            armSpinUnlock(lock)
        }
        return UInt64(n)
    }

    /// Legacy write syscall: fd 1 only, buf must lie inside the two user
    /// pages (the kernel never reads outside the run's own mapping on the
    /// user's say-so). Captured, capped, NOT echoed to the UART.
    private static func doWrite(fd: UInt64, buf: UInt64, len: UInt64) -> UInt64 {
        guard fd == 1 else { return UInt64.max }
        let base = UInt64(userBase)
        guard buf >= base, len <= UInt64(userSpan),
              buf + len <= base + UInt64(userSpan) else { return UInt64.max }
        let room = captureLimit - capture.count
        let n = min(Int(len), room)
        var i = 0
        while i < n {
            capture.append(UnsafeRawPointer(bitPattern: UInt(buf) &+ UInt(i))!
                .load(as: UInt8.self))
            i &+= 1
        }
        return UInt64(n)
    }

    /// "0x…" hex for the fault diagnostic (kprintHex prints to the UART;
    /// this one builds a String).
    private static func hex(_ v: UInt64) -> String {
        let digits: [UInt8] = [48, 49, 50, 51, 52, 53, 54, 55,
                               56, 57, 97, 98, 99, 100, 101, 102]
        var s = "0x"
        var shift = 60
        while shift >= 0 {
            s.append(Character(Unicode.Scalar(digits[Int((v >> UInt64(shift)) & 0xF)])))
            shift -= 4
        }
        return s
    }
}

/// Entry from Vectors.S sync_lower_entry. Runs on the kernel stack of the
/// thread that dropped to EL0 (a synchronous exception on that thread, with
/// IRQs masked) — allocation via the IRQ-atomic heap is safe here.
@_cdecl("swift_sync_lower")
func swiftSyncLower(_ esr: UInt64, _ frame: UnsafeMutablePointer<UInt64>) -> UInt64 {
    UserProcess.handleSyncFromEL0(esr: esr, frame: frame)
}
