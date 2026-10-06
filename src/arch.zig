//! The arch-neutral face of the per-architecture layer.
//!
//! Shared code calls through here and lets the target pick the implementation at
//! compile time, the same way src/soc.zig lets the board pick the addresses.
//! What is inherently one architecture's — the CSRs, the SBI, the GIC, the
//! architected timer — stays in src/arch/<arch> and is imported by that
//! architecture's own modules; only what every port must supply lives here.
//!
//! The contract is small on purpose. A new architecture joins by providing these
//! names, and then the parts of the firmware that are pure logic — the block,
//! filesystem, loader, and UEFI layers — build against it unchanged.

const builtin = @import("builtin");

pub const cpu = switch (builtin.cpu.arch) {
    .riscv64 => @import("arch/riscv/cpu.zig"),
    .aarch64 => @import("arch/arm64/cpu.zig"),
    else => @compileError("no arch layer for this target. See src/arch/"),
};

/// The monotonic counter. `now` reads it in ticks, `frequency` reports those
/// ticks per second, and the two together turn an interval a spec gives in
/// microseconds (Stall, a timer event) into ticks.
///
/// The counters differ in kind: RISC-V's machine timer runs at a rate the board
/// declares, while the AArch64 system counter reports its own rate in CNTFRQ_EL0.
pub const time = switch (builtin.cpu.arch) {
    .riscv64 => @import("arch/riscv/clint.zig"),
    .aarch64 => @import("arch/arm64/timer.zig"),
    else => @compileError("no monotonic counter for this target. See src/arch/"),
};
