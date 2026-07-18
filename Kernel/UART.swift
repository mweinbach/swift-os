// PL011 UART driver (QEMU virt: UART0 at 0x0900_0000) + kernel logging.

enum UART {
    /// PL011 base address. Starts at the compiled-in QEMU virt default so
    /// the very first boot output works; Machine.discover() re-points (and
    /// re-initializes) it when the device tree names a different pl011.
    /// Written only on the BSP during boot; read-only afterwards.
    static private(set) var base: UInt = 0x0900_0000

    // Register offsets from the PL011 base.
    private enum PL011 {
        static let drOff: UInt    = 0x00
        static let frOff: UInt    = 0x18
        static let ibrdOff: UInt  = 0x24
        static let fbrdOff: UInt  = 0x28
        static let lcrhOff: UInt  = 0x2C
        static let crOff: UInt    = 0x30
    }
    private static var dr: UInt    { base + PL011.drOff }
    private static var fr: UInt    { base + PL011.frOff }
    private static var ibrd: UInt  { base + PL011.ibrdOff }
    private static var fbrd: UInt  { base + PL011.fbrdOff }
    private static var lcrh: UInt  { base + PL011.lcrhOff }
    private static var cr: UInt    { base + PL011.crOff }

    /// Bytes dropped because the TX FIFO stayed full past the poll cap —
    /// i.e. the host end of the serial line stopped draining. Logging must
    /// never wedge the kernel, so a stalled FIFO costs bytes, not the boot.
    static private(set) var droppedTx: Int = 0

    static func initUART() {
        mmioWrite32(cr, 0)                    // disable
        mmioWrite32(ibrd, 13)                 // 24 MHz / (16 * 115200) = 13.02
        mmioWrite32(fbrd, 1)
        mmioWrite32(lcrh, (0b11 << 5) | (1 << 4)) // 8n1, FIFOs on
        mmioWrite32(cr, 0x301)                // UARTEN | TXE | RXE
    }

    /// Point the UART at a different PL011 base and re-initialize it there.
    /// No-op when the base is unchanged (QEMU virt: always the default).
    static func setBase(_ newBase: UInt) {
        guard newBase != base else { return }
        base = newBase
        initUART()
    }

    static func putc(_ c: UInt8) {
        // Bounded wait on TXFF: if the host serial stops draining, drop the
        // byte and count it instead of spinning forever (panic paths too).
        var spins = 0
        while mmioRead32(fr) & (1 << 5) != 0 { // TXFF
            spins += 1
            if spins >= 1_000_000 {
                droppedTx += 1
                return
            }
        }
        mmioWrite32(dr, UInt32(c))
    }

    /// Non-blocking: returns nil when the RX FIFO is empty.
    static func getc() -> UInt8? {
        if mmioRead32(fr) & (1 << 4) != 0 { return nil } // RXFE
        return UInt8(mmioRead32(dr) & 0xFF)
    }

    static func write(_ s: String) {
        for c in s.utf8 { putc(c) }
    }
}

/// Ring-buffer of boot/log lines, surfaced to userland as `bootLog`.
enum BootLog {
    static private(set) var lines: [String] = []

    static func add(_ s: String) {
        // klog is called from multiple threads (reaper, kworker): guard the
        // buffer against concurrent mutation.
        let flags = armIrqSave()
        lines.append(s)
        if lines.count > 128 { lines.removeFirst() }
        armIrqRestore(flags)
    }
}

// MARK: - kprint family (only safe after KernelHeap.initHeap for klog)
//
// Locking: every public entry point serializes on the SMP klog spinlock
// (klog_lock in Kernel/SMP.S) so partial lines from different cores can't
// interleave. The spinlock is NON-recursive, so two paths exist:
//   - the standalone kprint/kprintHex/kprintDec take the lock themselves
//     around their whole output sequence;
//   - klog() and smp_secondary_main hold the lock across several writes
//     and use the *Unlocked helpers — they must NOT call the self-locking
//     wrappers (re-taking the lock would spin forever).
// Hierarchy (see Kernel/Locks.swift): sched/tasks > klog > heap. klog's
// BootLog.add allocates under this lock — legal, the heap lock is lower.

/// UART write with NO locking: the caller MUST already hold the klog lock
/// (klog and smp_secondary_main do).
func kprintUnlocked(_ s: String) { UART.write(s) }

/// Hex dump, `0x` + 16 digits, with NO locking: caller holds the klog lock.
func kprintHexUnlocked(_ v: UInt64) {
    let digits: [UInt8] = [48,49,50,51,52,53,54,55,56,57,97,98,99,100,101,102]
    UART.write("0x")
    var shift = 60
    while shift >= 0 {
        UART.putc(digits[Int((v >> UInt64(shift)) & 0xF)])
        shift -= 4
    }
}

/// Decimal, with NO locking: caller holds the klog lock.
func kprintDecUnlocked(_ v: Int64) {
    if v < 0 { UART.write("-") ; kprintDecUnlocked(-v); return }
    if v >= 10 { kprintDecUnlocked(v / 10) }
    UART.putc(UInt8(48 + v % 10))
}

func kprint(_ s: String) {
    let lock = armKlogLockAddr()
    armSpinLock(lock)
    kprintUnlocked(s)
    armSpinUnlock(lock)
}

func kprintHex(_ v: UInt64) {
    let lock = armKlogLockAddr()
    armSpinLock(lock)
    kprintHexUnlocked(v)
    armSpinUnlock(lock)
}

func kprintDec(_ v: Int64) {
    let lock = armKlogLockAddr()
    armSpinLock(lock)
    kprintDecUnlocked(v)
    armSpinUnlock(lock)
}

/// Log line: serial + boot log buffer (used by the boot splash and /var/log/syslog).
/// Serialized through the SMP klog spinlock so lines from different cores
/// never interleave.
func klog(_ s: String) {
    let lock = armKlogLockAddr()
    armSpinLock(lock)
    UART.write(s)
    UART.write("\n")
    BootLog.add(s)
    armSpinUnlock(lock)
}

func kpanic(_ message: String) -> Never {
    // Full panic path: halts the other cores (SGI 1), dumps serial + screen.
    Panic.halt(message)
}
