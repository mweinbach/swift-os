// System-register accessors for Kernel/MMU.swift.
// Called only from MMU.initMMU() during boot — not IRQ-safe, not reentrant.

.globl mmu_read_id_aa64mmfr0
mmu_read_id_aa64mmfr0:
    mrs     x0, ID_AA64MMFR0_EL1
    ret

.globl mmu_write_mair
mmu_write_mair:
    msr     MAIR_EL1, x0
    ret

.globl mmu_write_tcr
mmu_write_tcr:
    msr     TCR_EL1, x0
    ret

.globl mmu_write_ttbr0
mmu_write_ttbr0:
    msr     TTBR0_EL1, x0
    ret

.globl mmu_read_sctlr
mmu_read_sctlr:
    mrs     x0, SCTLR_EL1
    ret

.globl mmu_write_sctlr
mmu_write_sctlr:
    msr     SCTLR_EL1, x0
    ret

.globl mmu_tlbi_vmalle1
mmu_tlbi_vmalle1:
    tlbi    vmalle1
    ret
