// PSCI (Power State Coordination Interface, ARM DEN 0022) call gate.
//
// Conduit on THIS setup: HVC, not SMC. QEMU's virt machine only emulates EL3
// with -M virt,secure=on; under the project's default flags there is no EL3,
// the CPU starts at EL2 (Boot.S drops to EL1) and QEMU's own DTB advertises
// psci { method = "hvc" } (verified via -M virt,dumpdtb=...). An `smc #0`
// here is an undefined instruction at EL1 — it sync-excepts (ESR 0x02000000).
// QEMU's PSCI firmware emulation lives at EL2 and answers `hvc #0`.

.section .text

// UInt arm_psci_call(UInt32 functionID x0, UInt arg1 x1, UInt arg2 x2, UInt arg3 x3)
// Standard AAPCS64 frame: args already in x0-x3, SMCCC result comes back in
// x0 (PSCI_SUCCESS or a negative error). SYSTEM_OFF / SYSTEM_RESET never
// return on success — the ret only runs when the call is denied/unsupported.
.globl arm_psci_call
arm_psci_call:
    hvc     #0
    ret
