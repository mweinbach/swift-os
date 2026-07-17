// ============================================================================
// EL0 userspace — run an embedded unprivileged blob and service its SVCs.
//
// A run is a synchronous round trip on the calling (main) thread:
// arm_run_el0 (Kernel/Userspace.S) stashes the kernel SP in a global,
// erets into EL0t (IRQs unmasked) at the blob entry with a private stack,
// and the only way back is the teardown path in sync_lower_entry
// (Kernel/Vectors.S): the exit syscall (or a user fault) reloads the
// stashed SP and jumps into arm_run_el0's epilogue, so from Swift's
// perspective armRunEl0 simply returns a marker. While at EL0 the CPU is
// fully preemptible: timer IRQs take the lower-EL IRQ vector row into the
// regular irq_entry, whose full frame (incl. SPSR/ELR) lets the scheduler
// switch away and later eret right back into the blob.
//
// Memory: two contiguous pages from allocPages — page 0 holds the blob
// (entry at offset 0), page 1 is the user stack. MMU.allowEL0 marks the
// covering 2 MiB L2 slot(s) EL0+EL1 RW (stage-1 granularity: the whole
// slot, neighbours included — see MMU.swift). Pages are allocated once and
// kept; every run re-zeroes and re-copies, so runs are independent.
//
// ================================= SYSCALL ABI =============================
// svc #0, syscall number in x8, args in x0-x5, result in x0. Unknown
// numbers return -1 (0xFFFF_FFFF_FFFF_FFFF) in x0. Vector registers are
// NOT preserved across an svc (only x19-x29 survive, via the AAPCS
// callee-saved guarantee) — keep the blob integer-only.
//   0  write(fd=x0, buf=x1, len=x2) -> x0 = bytes written, or -1 on a bad
//      fd (only fd 1 exists) or a buf range outside the two user pages.
//      Bytes are captured into a per-run buffer (NOT the UART) that
//      runDemo() returns; capped at captureLimit, writes past the cap are
//      short writes.
//   1  uptime_ms() -> x0 = Clock.uptimeMs.
//   2  exit(code=x0) — ends the run; never returns to the blob.
//   3  yield() -> x0 = 0. Scheduler.yield() from the exception handler.
//
// User crash guard: any non-SVC synchronous exception from EL0 (undefined
// instruction, data/instruction abort, …) kills the run instead of the
// kernel: runDemo returns "<udemo>: user program faulted (ESR=…, ELR=…)".
// A lower-EL sync exception with no active run is still a kernel panic —
// it cannot happen unless something is already badly wrong.
// ============================================================================

@_silgen_name("arm_run_el0")
private func armRunEl0(_ entry: UInt, _ userSP: UInt) -> UInt64

enum UserProcess {
    /// Pinned integration API: Userland/Shell.swift's `udemo` command calls
    /// this and prints the result like any command output.
    static func runDemo() -> String {
        guard Config.enableUserland else { return "udemo: userspace disabled" }
        return runBlob(UserBlob.bytes)
    }

    // MARK: - Run state

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

    // MARK: - Loader / runner

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
    /// 2 = user faulted (both tear the run down via el0_kernel_save).
    ///
    /// NOTE — no ELR fixup on SVC: on AArch64, SVC entry already sets
    /// ELR_EL1 to the instruction AFTER the svc (verified against QEMU's
    /// -d int trace and Linux's el0_svc, which never adjusts the PC).
    /// "Advancing ELR past the svc" here would skip the next user
    /// instruction. Aborts/undefined instructions instead report ELR = the
    /// faulting instruction itself — exactly what the fault path wants.
    static func handleSyncFromEL0(esr: UInt64, frame: UnsafeMutablePointer<UInt64>) -> UInt64 {
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

    /// write syscall: fd 1 only, buf must lie inside the two user pages
    /// (the kernel never reads outside the run's own mapping on the user's
    /// say-so). Captured, capped, NOT echoed to the UART.
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
