// SMP bring-up for the Pi-5-profile 4-core machine.
//
// Stage: secondaries run NO shared-state kernel code. Each prints one
// allocation-free line (spinlock-guarded) and parks in wfi. The scheduler,
// heap, and all drivers remain main-CPU only until per-core run queues and
// real locking arrive (IRQ-mask guards do not protect across cores).

@_silgen_name("arm_spin_lock") func armSpinLock(_ lock: UInt)
@_silgen_name("arm_spin_unlock") func armSpinUnlock(_ lock: UInt)
@_silgen_name("arm_klog_lock_addr") func armKlogLockAddr() -> UInt
@_silgen_name("arm_smp_entry_addr") private func armSmpEntryAddr() -> UInt
@_silgen_name("arm_psci_call") private func armPsciCall2(_ function: UInt32, _ arg1: UInt, _ arg2: UInt, _ arg3: UInt) -> UInt

enum SMP {
    /// Bring up secondary CPUs (1 ... Config.cpuCount-1) via PSCI CPU_ON.
    static func startSecondaries() {
        guard Config.smpEnabled else { return }
        var cpu: UInt = 1
        while cpu < UInt(Config.cpuCount) {
            guard let stack = KernelHeap.allocPages(4) else {
                klog("[smp] stack allocation failed — secondary bring-up stopped")
                return
            }
            let ctx = stack + UInt(4 * 4096) - 16
            UnsafeMutablePointer<UInt64>(bitPattern: ctx)!.pointee = UInt64(cpu)
            let rc = armPsciCall2(0xC400_0003, cpu, armSmpEntryAddr(), ctx)
            if rc != 0 {
                klog("[smp] CPU_ON failed for cpu \(cpu) (rc=\(Int64(bitPattern: UInt64(rc))))")
            }
            cpu += 1
        }
    }
}

/// Secondary CPU entry (from asm). Deliberately allocation-free: BootLog and
/// the heap are main-CPU-only, so this uses kprint (UART) under the klog
/// spinlock, then parks.
@_silgen_name("smp_secondary_main")
func smpSecondaryMain(_ cpu: UInt64) -> Never {
    let lock = armKlogLockAddr()
    armSpinLock(lock)
    kprint("[smp] cpu ")
    kprintDec(Int64(cpu))
    kprint(" online (parked)\n")
    armSpinUnlock(lock)
    while true { armWfi() }
}
