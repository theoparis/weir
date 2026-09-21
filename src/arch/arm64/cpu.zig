//! Low-level AArch64 CPU primitives shared across the firmware.

const sysreg = @import("sysreg.zig");
const psci = @import("psci.zig");

/// The exception level the caller runs at (0-3).
pub fn currentEl() u2 {
    return @truncate(sysreg.read("CurrentEL") >> 2);
}

/// Wait for an event. AArch64's idle hint, and the counterpart of the RISC-V
/// port's `wfi`.
pub inline fn wfe() void {
    asm volatile ("wfe");
}

/// Idle until something happens. The arch-neutral name for the idle hint, so a
/// loop that waits for work — an application processor's holding loop — does not
/// have to know which architecture it is on.
pub inline fn idle() void {
    wfe();
}

/// Park the core forever. This is the single stop-here sink, as in the RISC-V
/// port: panics, unhandled traps, and an exhausted boot all converge here.
pub fn halt() noreturn {
    while (true) wfe();
}

/// Reset the machine through PSCI, which is the only way from a core that does
/// not own a reset controller it can reach.
pub fn reset() noreturn {
    psci.systemReset();
    halt();
}

/// Stop the machine. PSCI is the architected way to ask the level above the
/// firmware to power the machine down, and it is the only way on a core whose
/// own reset controller the firmware cannot reach.
pub fn powerOff() noreturn {
    psci.systemOff();
    // A monitor that does not implement SYSTEM_OFF returns, so park rather than
    // run on into whatever follows.
    halt();
}

/// Make instructions just written visible to the fetch path. The loader writes
/// an image and then enters it, and AArch64 does not snoop between the data and
/// instruction paths, so the new code has to be visible before it is fetched.
/// `ic iallu` covers the whole instruction cache to the point of unification,
/// which is what the loader needs: it does not know which lines it replaced.
pub fn syncInstructionCache() void {
    asm volatile ("ic iallu");
    asm volatile ("dsb ish");
    asm volatile ("isb");
}
