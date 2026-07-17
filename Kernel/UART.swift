// PL011 UART driver (QEMU virt: UART0 at 0x0900_0000) + kernel logging.

private enum PL011 {
    static let base: UInt = 0x0900_0000
    static let dr    = base + 0x00
    static let fr    = base + 0x18
    static let ibrd  = base + 0x24
    static let fbrd  = base + 0x28
    static let lcrh  = base + 0x2C
    static let cr    = base + 0x30
}

enum UART {
    static func initUART() {
        mmioWrite32(PL011.cr, 0)                    // disable
        mmioWrite32(PL011.ibrd, 13)                 // 24 MHz / (16 * 115200) = 13.02
        mmioWrite32(PL011.fbrd, 1)
        mmioWrite32(PL011.lcrh, (0b11 << 5) | (1 << 4)) // 8n1, FIFOs on
        mmioWrite32(PL011.cr, 0x301)                // UARTEN | TXE | RXE
    }

    static func putc(_ c: UInt8) {
        while mmioRead32(PL011.fr) & (1 << 5) != 0 { } // TXFF
        mmioWrite32(PL011.dr, UInt32(c))
    }

    /// Non-blocking: returns nil when the RX FIFO is empty.
    static func getc() -> UInt8? {
        if mmioRead32(PL011.fr) & (1 << 4) != 0 { return nil } // RXFE
        return UInt8(mmioRead32(PL011.dr) & 0xFF)
    }

    static func write(_ s: String) {
        for c in s.utf8 { putc(c) }
    }
}

/// Ring-buffer of boot/log lines, surfaced to userland as `bootLog`.
enum BootLog {
    static private(set) var lines: [String] = []

    static func add(_ s: String) {
        lines.append(s)
        if lines.count > 128 { lines.removeFirst() }
    }
}

// MARK: - kprint family (only safe after KernelHeap.initHeap for klog)

func kprint(_ s: String) { UART.write(s) }

func kprintHex(_ v: UInt64) {
    let digits: [UInt8] = [48,49,50,51,52,53,54,55,56,57,97,98,99,100,101,102]
    UART.write("0x")
    var shift = 60
    while shift >= 0 {
        UART.putc(digits[Int((v >> UInt64(shift)) & 0xF)])
        shift -= 4
    }
}

func kprintDec(_ v: Int64) {
    if v < 0 { UART.write("-") ; kprintDec(-v); return }
    if v >= 10 { kprintDec(v / 10) }
    UART.putc(UInt8(48 + v % 10))
}

/// Log line: serial + boot log buffer (used by the boot splash and /var/log/syslog).
func klog(_ s: String) {
    UART.write(s)
    UART.write("\n")
    BootLog.add(s)
}

func kpanic(_ message: String) -> Never {
    armIrqDisable()
    UART.write("\n*** KERNEL PANIC: ")
    UART.write(message)
    UART.write(" ***\n")
    while true { armWfi() }
}
