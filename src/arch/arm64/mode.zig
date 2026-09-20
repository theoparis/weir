//! Privilege-level setup. The AArch64 counterpart of the RISC-V port's
//! mode.zig: it moves the core to the level the firmware runs at and arms the
//! traps that level needs.

const sysreg = @import("sysreg.zig");

/// Leave EL2 for EL1 and continue at `entry`, which does not return.
///
/// QEMU's virt machine resets into EL2 when virtualization is on, and the
/// firmware runs at EL1: on AArch64 that is the level the UEFI specification
/// places the boot loader and the OS, and it keeps PSCI available to them.
///
/// `entry` is reached with SP_EL1 selected, since EL1h does not inherit the
/// caller's stack: it must load SP before it calls anything.
pub fn enterEl1(entry: usize) noreturn {
    // Nothing at EL1 may trap to EL2 once control passes down: the firmware has
    // no EL2 handlers. FP/SIMD, the physical counter, and the physical timer are
    // all off by default and all reachable only through the registers below.
    sysreg.set("CPACR_EL1", fp_enable);
    sysreg.set("CNTHCTL_EL2", cnthctl_el1pcten | cnthctl_el1pcen);
    // IMO/FMO/AMO route physical IRQ, FIQ, and SError to EL2. Clearing them
    // leaves every exception at EL1. The rest of the register, RW in particular,
    // is left as reset set it.
    sysreg.clear("HCR_EL2", hcr_imo | hcr_fmo | hcr_amo);
    sysreg.write("ELR_EL2", entry);
    // EL1h (M[3:0] = 0b0101): SP_EL1, and every interrupt masked on entry.
    sysreg.write("SPSR_EL2", spsr_el1h | spsr_daif_masked);
    asm volatile ("dsb sy");
    asm volatile ("isb");
    asm volatile ("eret");
    unreachable;
}

/// FPEN = 0b11: no FP/SIMD trap at EL0 or EL1. Zig's code generation uses NEON
/// for bulk copies and struct moves, so without this the first such instruction
/// faults.
const fp_enable: u64 = 3 << 20;

/// CNTHCTL_EL2.EL1PCTEN: EL1 may read the physical counter, CNTPCT_EL0.
const cnthctl_el1pcten: u64 = 1 << 0;
/// CNTHCTL_EL2.EL1PCEN: EL1 may use the physical timer. EL0 is deliberately left
/// trapped, since nothing at EL0 has asked for it.
const cnthctl_el1pcen: u64 = 1 << 1;

const hcr_imo: u64 = 1 << 4;
const hcr_fmo: u64 = 1 << 3;
const hcr_amo: u64 = 1 << 5;

const spsr_el1h: u64 = 0b0101;
/// D, A, I, F masked: the EL1 entry starts with interrupts off and unmasks them
/// once the handlers and the interrupt controller are in place.
const spsr_daif_masked: u64 = 0xf << 6;
