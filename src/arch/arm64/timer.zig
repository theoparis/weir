//! The AArch64 architected timers: the system counter and the EL1 physical
//! timer.
//!
//! This replaces the RISC-V port's CLINT machine timer. Two things differ, and
//! both make the port smaller: the counter's rate is architectural (CNTFRQ_EL0)
//! rather than a board property, so no device tree is consulted for it, and the
//! comparator is a register rather than an MMIO window, so there is no base
//! address to discover either.

const sysreg = @import("sysreg.zig");

/// Ticks per second of the system counter. QEMU's virtual generic timer reports
/// 62.5 MHz; the value is whatever the previous stage left in CNTFRQ_EL0.
pub fn frequency() u64 {
    return sysreg.read("CNTFRQ_EL0");
}

/// The free-running system counter: monotonic, and the base for every delay and
/// for any wall-clock derivation that has no RTC. This is the name the shared
/// arch face (`src/arch.zig`) reads, so firmware services built on a clock do
/// not have to know which counter the machine has.
pub fn now() u64 {
    return sysreg.read("CNTPCT_EL0");
}

/// Arm the EL1 physical timer to fire `ticks` from now, relative to the counter.
/// Rewriting it on every expiry is what keeps the period immune to a late
/// interrupt handler.
pub fn setTimer(ticks: u64) void {
    sysreg.write("CNTP_TVAL_EL0", ticks);
}

/// Enable the EL1 physical timer with its interrupt unmasked.
pub fn enable() void {
    sysreg.write("CNTP_CTL_EL0", ctl_enable);
}

/// Stop the timer: no compare, no interrupt.
pub fn disable() void {
    sysreg.write("CNTP_CTL_EL0", 0);
}

const ctl_enable: u64 = 1 << 0;
