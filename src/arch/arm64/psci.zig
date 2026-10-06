//! PSCI, the Power State Coordination Interface: how a core starts or stops
//! another core on AArch64. The firmware is the caller here; the OS calls the
//! same conduit later.
//!
//! The tree's `psci` node gives the conduit (`method`), and this port implements
//! the SMC/HVC form of it. QEMU's virt machine declares `hvc`, which is what a
//! core with an EL2 available uses: the call traps to the exception level above
//! the firmware, which is where QEMU's PSCI implementation lives.
//!
//! The calls are the architected ones, not QEMU's: function ids come from the
//! PSCI specification, so the same code speaks to a real monitor.

const psci_0_2 = 0x8400_0000;
const psci_1_0 = 0xc400_0000;

/// `PSCI_CPU_ON`: power up a core at an entry point, with a context value.
const cpu_on = psci_1_0 | 0x03;
/// `PSCI_SYSTEM_OFF`: leave the machine powered down. Nothing comes back.
const system_off = psci_0_2 | 0x08;
/// `PSCI_SYSTEM_RESET`: restart the machine. Nothing of this image comes back.
const system_reset = psci_0_2 | 0x09;

pub const Success = 0;
pub const NotSupported = -1;
pub const InvalidParams = -2;
pub const AlreadyOn = -3;

/// The result of a PSCI call: `SUCCESS`, or one of the negative status codes
/// above. PSCI returns a 32-bit integer sign-extended into the register.
pub const Status = i32;

/// Start the core whose MPIDR affinity value is `target`, entering at `entry`
/// with `context` in x0.
///
/// `entry` is a physical address, and it must be a location that core can
/// execute from before it has a stack or a page table of its own: a monitor
/// hands control over with the MMU off and the caches as that core left them.
pub fn cpuOn(target: u64, entry: usize, context: u64) Status {
    const ret = call4(cpu_on, target, entry, context);
    return @bitCast(@as(u32, @truncate(ret)));
}

/// Stop the machine. On a hosted machine this is how the firmware leaves; on a
/// real one it may not return at all.
pub fn systemOff() void {
    _ = call4(system_off, 0, 0, 0);
}

/// Restart the machine. The monitor may return, so the caller has to decide what
/// to do with a monitor that does not implement it.
pub fn systemReset() void {
    _ = call4(system_reset, 0, 0, 0);
}

/// Issue a PSCI call with the HVC conduit and return x0.
fn call4(function_id: u64, a1: u64, a2: u64, a3: u64) u64 {
    return asm volatile ("hvc #0"
        : [ret] "={x0}" (-> u64),
        : [id] "{x0}" (function_id),
          [a1] "{x1}" (a1),
          [a2] "{x2}" (a2),
          [a3] "{x3}" (a3),
        : .{ .memory = true });
}
