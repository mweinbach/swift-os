// System power control via PSCI 0.2 (ARM DEN 0022) over HVC — see PSCI.S for
// why the conduit is HVC on this QEMU setup (no EL3 by default).
// QEMU's virt machine implements SYSTEM_OFF (the emulator exits, status 0)
// and SYSTEM_RESET (the machine resets; exits instead with -no-reboot).

@_silgen_name("arm_psci_call")
private func armPsciCall(_ function: UInt32, _ arg1: UInt, _ arg2: UInt, _ arg3: UInt) -> UInt

enum Power {
    /// PSCI 0.2 function IDs (SMC32 fast calls).
    private static let systemOffID: UInt32 = 0x8400_0008
    private static let systemResetID: UInt32 = 0x8400_0009

    /// Power the machine off. Under QEMU the emulator process exits (status 0).
    static func shutdown() -> Never {
        klog("power: system off requested")
        settleSerial()
        let result = armPsciCall(systemOffID, 0, 0, 0)
        kpanic("power: PSCI SYSTEM_OFF unexpectedly returned \(result)")
    }

    /// Reset the machine. Under QEMU the guest boots again from scratch (or
    /// the emulator exits when QEMU was started with -no-reboot).
    static func reboot() -> Never {
        klog("power: system reset requested")
        settleSerial()
        let result = armPsciCall(systemResetID, 0, 0, 0)
        kpanic("power: PSCI SYSTEM_RESET unexpectedly returned \(result)")
    }

    /// Give the PL011 a beat to drain its TX FIFO: klog bytes are only IN the
    /// FIFO when klog returns, still shifting out at 115200 baud — without the
    /// pause the SMC would cut power mid-line. Interrupts are then masked so
    /// nothing runs between the final byte and the power-down.
    private static func settleSerial() {
        let deadline = Clock.uptimeMs &+ 60
        while Clock.uptimeMs < deadline { }
        armIrqDisable()
    }
}
