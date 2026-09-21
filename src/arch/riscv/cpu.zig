//! Low-level RISC-V CPU primitives shared across the firmware.

const platform = @import("../../platform.zig");

/// Wait for an interrupt. Hint that the hart can idle until the next one fires.
pub inline fn wfi() void {
    asm volatile ("wfi");
}

/// Idle until something happens. The arch-neutral name for the idle hint, so a
/// loop that waits for work does not have to know which architecture it is on.
pub inline fn idle() void {
    wfi();
}

/// Park the hart forever. This is the single stop-here sink. Panics, unhandled
/// traps, post-shutdown, and an exhausted boot all converge here.
pub fn halt() noreturn {
    while (true) asm volatile ("wfi");
}

/// Stop the machine. The SiFive-style test finisher is how a RISC-V board here
/// signals a power-off request; the address comes from the device tree, and a
/// board without one has nothing to signal, so the write is whatever happens and
/// the park below is what actually stops the hart.
pub fn powerOff() noreturn {
    finisher(0x5555);
    halt();
}

/// Reset the machine, through the same finisher's reset code. A machine that
/// ignores the write never comes back, so the halt after it is the last resort
/// rather than the plan.
pub fn reset() noreturn {
    finisher(0x7777);
    halt();
}

/// Write the SiFive test finisher's completion code.
fn finisher(code: u32) void {
    const device: *volatile u32 = @ptrFromInt(platform.resetBase());
    device.* = code;
}

/// Make instructions just written visible to the fetch path. The loader writes
/// an image and then enters it, and a hart may have the old bytes in its
/// pipeline: RISC-V has no data cache to clean, so the fence is the whole job.
pub inline fn syncInstructionCache() void {
    asm volatile ("fence.i" ::: .{ .memory = true });
}
