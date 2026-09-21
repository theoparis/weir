//! The 16 EL1 exception vectors and the handlers behind them.
//!
//! `install` loads this module's vector table into VBAR_EL1; the reset path
//! calls it once the firmware is at EL1. The IRQ entry saves the interrupted
//! context (including the vector registers, which Zig's bulk copies keep live),
//! runs the platform's interrupt handler, and returns. Everything else reports
//! what the core recorded about the fault and parks: an unhandled exception is
//! never silent.

const console = @import("../../console/console.zig");
const soc = @import("soc");
const cpu = @import("cpu.zig");
const sysreg = @import("sysreg.zig");

/// The interrupt the bring-up runs on: the EL1 physical timer, the second of the
/// four the timer node names (secure EL1, non-secure EL1, virtual, non-secure
/// EL2). A PPI is private to the core, so the GIC routes it to that core rather
/// than through the distributor's shared lines.
///
/// The board's device tree is the authority — the same number goes into the ACPI
/// GTDT, so the OS arms the timer the firmware ran on — and PPI 30 is the
/// convention this falls back to when the tree does not name one.
pub const timer_irq: u32 = if (soc.timer_gsivs[1] != 0) soc.timer_gsivs[1] else 30;

/// Install the vector table as the EL1 exception base.
pub fn install() void {
    sysreg.write("VBAR_EL1", @intFromPtr(&vectorTable));
    asm volatile ("isb");
}

/// The platform's interrupt handler, installed once an interrupt controller and
/// a timer exist. Null means an IRQ arrived with nothing to service it: the entry
/// returns without claiming, so the core keeps running rather than parking on a
/// fault that is really a missing handler.
pub var irq_handler: ?*const fn () callconv(.c) void = null;

/// The 16 EL1 vectors, in the order the architecture indexes them: four groups
/// (current EL with SP_EL0, current EL with SP_ELx, lower EL AArch64, lower EL
/// AArch32) of four (synchronous, IRQ, FIQ, SError). Each slot is 0x80 bytes, so
/// the padding is what makes a group line up with the exception the core
/// reports. VBAR_EL1 requires a 2 KiB-aligned base; the generated linker script
/// aligns the `.vectors` output section for it.
// zippy:ignore naming_convention -- the symbol is the architectural name
export fn vectorTable() linksection(".vectors") callconv(.naked) void {
    asm volatile (
        \\ .balign 0x800
        \\ .balign 0x80
        \\ b arm64SyncFatal
        \\ .balign 0x80
        \\ b arm64IrqEntry
        \\ .balign 0x80
        \\ b arm64Unhandled
        \\ .balign 0x80
        \\ b arm64Unhandled
        \\ .balign 0x80
        \\ b arm64SyncFatal
        \\ .balign 0x80
        \\ b arm64IrqEntry
        \\ .balign 0x80
        \\ b arm64Unhandled
        \\ .balign 0x80
        \\ b arm64Unhandled
        \\ .balign 0x80
        \\ b arm64Unhandled
        \\ .balign 0x80
        \\ b arm64Unhandled
        \\ .balign 0x80
        \\ b arm64Unhandled
        \\ .balign 0x80
        \\ b arm64Unhandled
        \\ .balign 0x80
        \\ b arm64Unhandled
        \\ .balign 0x80
        \\ b arm64Unhandled
        \\ .balign 0x80
        \\ b arm64Unhandled
        \\ .balign 0x80
        \\ b arm64Unhandled
    );
}

/// IRQ entry. Saves the caller-visible state the interrupted code may hold, runs
/// the handler, then restores and returns with `eret`.
///
/// Every general-purpose register is saved rather than the calling-convention
/// set: the interrupted code was not at a call boundary. The vector registers
/// are saved for the same reason, and because Zig's copies and struct moves use
/// them. The vector table branches here, so this is ordinary read-only code and
/// stays out of the `.vectors` section, which must hold nothing but the table.
export fn arm64IrqEntry() callconv(.naked) void {
    asm volatile (
        \\ sub sp, sp, #0x300
        \\ stp x0, x1, [sp, #0x000]
        \\ stp x2, x3, [sp, #0x010]
        \\ stp x4, x5, [sp, #0x020]
        \\ stp x6, x7, [sp, #0x030]
        \\ stp x8, x9, [sp, #0x040]
        \\ stp x10, x11, [sp, #0x050]
        \\ stp x12, x13, [sp, #0x060]
        \\ stp x14, x15, [sp, #0x070]
        \\ stp x16, x17, [sp, #0x080]
        \\ stp x18, x19, [sp, #0x090]
        \\ stp x20, x21, [sp, #0x0a0]
        \\ stp x22, x23, [sp, #0x0b0]
        \\ stp x24, x25, [sp, #0x0c0]
        \\ stp x26, x27, [sp, #0x0d0]
        \\ stp x28, x29, [sp, #0x0e0]
        \\ str x30, [sp, #0x0f0]
        \\ stp q0, q1, [sp, #0x100]
        \\ stp q2, q3, [sp, #0x120]
        \\ stp q4, q5, [sp, #0x140]
        \\ stp q6, q7, [sp, #0x160]
        \\ stp q8, q9, [sp, #0x180]
        \\ stp q10, q11, [sp, #0x1a0]
        \\ stp q12, q13, [sp, #0x1c0]
        \\ stp q14, q15, [sp, #0x1e0]
        \\ stp q16, q17, [sp, #0x200]
        \\ stp q18, q19, [sp, #0x220]
        \\ stp q20, q21, [sp, #0x240]
        \\ stp q22, q23, [sp, #0x260]
        \\ stp q24, q25, [sp, #0x280]
        \\ stp q26, q27, [sp, #0x2a0]
        \\ stp q28, q29, [sp, #0x2c0]
        \\ stp q30, q31, [sp, #0x2e0]
        \\ bl arm64Irq
        \\ ldp q30, q31, [sp, #0x2e0]
        \\ ldp q28, q29, [sp, #0x2c0]
        \\ ldp q26, q27, [sp, #0x2a0]
        \\ ldp q24, q25, [sp, #0x280]
        \\ ldp q22, q23, [sp, #0x260]
        \\ ldp q20, q21, [sp, #0x240]
        \\ ldp q18, q19, [sp, #0x220]
        \\ ldp q16, q17, [sp, #0x200]
        \\ ldp q14, q15, [sp, #0x1e0]
        \\ ldp q12, q13, [sp, #0x1c0]
        \\ ldp q10, q11, [sp, #0x1a0]
        \\ ldp q8, q9, [sp, #0x180]
        \\ ldp q6, q7, [sp, #0x160]
        \\ ldp q4, q5, [sp, #0x140]
        \\ ldp q2, q3, [sp, #0x120]
        \\ ldp q0, q1, [sp, #0x100]
        \\ ldp x28, x29, [sp, #0x0e0]
        \\ ldr x30, [sp, #0x0f0]
        \\ ldp x26, x27, [sp, #0x0d0]
        \\ ldp x24, x25, [sp, #0x0c0]
        \\ ldp x22, x23, [sp, #0x0b0]
        \\ ldp x20, x21, [sp, #0x0a0]
        \\ ldp x18, x19, [sp, #0x090]
        \\ ldp x16, x17, [sp, #0x080]
        \\ ldp x14, x15, [sp, #0x070]
        \\ ldp x12, x13, [sp, #0x060]
        \\ ldp x10, x11, [sp, #0x050]
        \\ ldp x8, x9, [sp, #0x040]
        \\ ldp x6, x7, [sp, #0x030]
        \\ ldp x4, x5, [sp, #0x020]
        \\ ldp x2, x3, [sp, #0x010]
        \\ ldp x0, x1, [sp, #0x000]
        \\ add sp, sp, #0x300
        \\ eret
    );
}

/// The C entry the IRQ vector calls.
export fn arm64Irq() callconv(.c) void {
    if (irq_handler) |handler| handler();
}

/// The synchronous-exception entry. The firmware has no continuable trap to
/// service at EL1, so this reports and parks.
export fn arm64SyncFatal() callconv(.c) noreturn {
    report("synchronous exception");
    cpu.halt();
}

/// Every entry the firmware does not implement (FIQ, SError, and anything from a
/// lower exception level).
export fn arm64Unhandled() callconv(.c) noreturn {
    report("unhandled exception");
    cpu.halt();
}

fn report(kind: []const u8) void {
    const esr = sysreg.read("ESR_EL1");
    const far = sysreg.read("FAR_EL1");
    const elr = sysreg.read("ELR_EL1");
    const spsr = sysreg.read("SPSR_EL1");
    if (!console.ready) {
        // A fault before the console exists is the one report nobody can afford
        // to lose, and the vector table is installed before anything can fault.
        // Straight to the UART, with no driver and no formatting.
        console.emergencyWriteAll("\n[arm64] TRAP esr=");
        console.emergencyWriteHex(esr);
        console.emergencyWriteAll(" far=");
        console.emergencyWriteHex(far);
        console.emergencyWriteAll(" elr=");
        console.emergencyWriteHex(elr);
        console.emergencyWriteAll(" spsr=");
        console.emergencyWriteHex(spsr);
        console.emergencyWriteAll("\n");
        return;
    }
    console.out.print("\n[arm64] {s}: {s} (ec {x})\n", .{ kind, exceptionClass(esr >> 26), esr >> 26 }) catch {};
    console.out.print("[arm64] esr {x}, far {x}, elr {x}, spsr {x}\n", .{ esr, far, elr, spsr }) catch {};
}

/// Name the exception classes a bring-up actually hits. The field is 6 bits and
/// most values are unallocated; the rest name something real only in the context
/// of the instruction that trapped, so they stay unnamed.
fn exceptionClass(ec: u64) []const u8 {
    return switch (ec) {
        0x00 => "unknown",
        0x01 => "trapped WFI or WFE",
        0x07 => "trapped FP/SIMD access",
        0x0e => "illegal execution state",
        0x15 => "SVC from AArch64",
        0x18 => "trapped MSR/MRS",
        0x20 => "instruction abort from lower EL",
        0x21 => "instruction abort from same EL",
        0x22 => "PC alignment fault",
        0x24 => "data abort from lower EL",
        0x25 => "data abort from same EL",
        0x26 => "SP alignment fault",
        0x3c => "BRK",
        else => "see ESR_EL1",
    };
}
