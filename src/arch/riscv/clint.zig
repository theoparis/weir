//! CLINT (Core-Local Interruptor). It provides the machine timer and inter-hart
//! software interrupts. A thin adapter over conduit's clint driver. It reads the
//! base from platform.clintBase() on each call, so it follows runtime discovery.

const conduit = @import("conduit");
const platform = @import("../../platform.zig");
const soc = @import("soc");

fn dev() conduit.driver.clint.Clint {
    return conduit.driver.clint.bind(conduit.Mmio.direct(platform.clintBase()));
}

/// True after M-mode confirms the Sstc extension is usable. menvcfg.STCE stays
/// set on readback. When false, set_timer must arm the machine timer through the
/// CLINT. The M-mode timer IRQ then relays to S-mode as STIP. A minimal core
/// without Sstc, like creek, needs that path. mode.enter() sets this once.
pub var sstc: bool = false;

/// Current value of the global timer.
pub fn time() u64 {
    return dev().time();
}

/// The monotonic counter, in `frequency` ticks per second. This is the name the
/// shared arch face (`src/arch.zig`) calls; RISC-V code that knows it is talking
/// to the CLINT keeps using `time`.
pub fn now() u64 {
    return time();
}

/// Ticks per second of the machine timer. The RISC-V counter's rate is a
/// platform property, so this comes from the SoC description, not the device.
pub fn frequency() u64 {
    return soc.timebase_hz;
}

/// Program the machine timer compare for `hart`. A machine timer interrupt
/// fires when `time() >= value`.
pub fn setTimecmp(hart: usize, value: u64) void {
    dev().setTimecmp(hart, value);
}

/// Raise a machine software interrupt on `hart`.
pub fn sendIpi(hart: usize) void {
    dev().sendIpi(hart);
}

/// Acknowledge (clear) the machine software interrupt on `hart`.
pub fn clearIpi(hart: usize) void {
    dev().clearIpi(hart);
}
