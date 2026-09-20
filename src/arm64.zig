//! AArch64 reset entry and bring-up.
//!
//! QEMU's aarch64 `virt` machine maps `-bios` into pflash0 at address 0 and
//! resets there, so this image runs in place from read-only flash, the way the
//! FSBL runs from SPI-NOR on River. QEMU resets the core into EL2 when
//! virtualization is on; the firmware runs at EL1, where the UEFI specification
//! places the boot loader and the OS, so the entry drops a level first.
//!
//! Four things have to happen before compiled code can be trusted, and they
//! happen in this order. The reset path gives the core a stack and turns on
//! FP/SIMD, which Zig's code generation assumes. The segment copy gives it
//! writable state, with integer byte accesses so it needs neither. The exception
//! vectors go in, so anything that does go wrong reports. Then `mmu.init` gives
//! it Normal memory: until that step every address is Device-nGnRnE, where an
//! unaligned access faults, and copies of automatic-layout structs and number
//! formatting both make unaligned accesses without meaning to.
//!
//! Everything above the bring-up is shared with the RISC-V firmware: the
//! console, the device-tree-driven platform layer, and conduit all come from
//! src/. What is AArch64-specific lives in src/arch/arm64.

const std = @import("std");
const conduit = @import("conduit");
const console = @import("console/console.zig");
const soc = @import("soc");
const varstore = @import("uefi/varstore.zig");
const tpm = @import("tpm/tpm.zig");
const uefi = @import("uefi/uefi.zig");
const pe = @import("loader/pe.zig");
const acpi_qemu = @import("acpi/qemu.zig");
const manager = @import("boot/manager.zig");
const psci = @import("arch/arm64/psci.zig");
const cpu = @import("arch/arm64/cpu.zig");
const el = @import("arch/arm64/mode.zig");
const mmu = @import("arch/arm64/mmu.zig");
const timer = @import("arch/arm64/timer.zig");
const trap = @import("arch/arm64/trap.zig");

/// Firmware panic handler. Reports on the console, then parks the core, as the
/// RISC-V firmware does. Before the console is bound it reports through the
/// emergency path, since a panic in the first instructions of the firmware is
/// exactly the one worth reading.
pub const panic = std.debug.FullPanic(panicHandler);

fn panicHandler(msg: []const u8, ret_addr: ?usize) noreturn {
    if (console.ready) {
        console.out.print("\n[arm64] PANIC: {s} (ra={?x})\n", .{ msg, ret_addr }) catch {};
    } else {
        console.emergencyWriteAll("\n[arm64] PANIC: ");
        console.emergencyWriteAll(msg);
        console.emergencyWriteAll(" (ra=");
        if (ret_addr) |ra| console.emergencyWriteHex(ra) else console.emergencyWriteAll("?");
        console.emergencyWriteAll(")\n");
    }
    cpu.halt();
}

// _start is the ELF entry symbol the generated linker script and the CPU reset
// vector need by that exact name.
// zippy:ignore naming_convention
export fn _start() linksection(".text.boot") callconv(.naked) noreturn {
    asm volatile (
        \\ msr daifset, #0xf
        // The boot protocol hands the machine's device tree in x0, and this is
        // the last moment it exists: the segment copy below clears .bss and the
        // rest of the bring-up uses x0 as scratch. Keep it in a callee-saved
        // register until there is somewhere to put it.
        \\ mov x19, x0
        // A stack before anything pushes. The generated linker script puts
        // _stack_top at the top of the /memory window it took from the tree.
        \\ adrp x0, _stack_top
        \\ add x0, x0, :lo12:_stack_top
        \\ mov sp, x0
        // FP/SIMD is off at reset, and Zig's code generation uses NEON for bulk
        // copies and struct moves, so it must be on before the first
        // compiler-generated instruction. CPTR_EL2 only exists at EL2.
        \\ mrs x1, CurrentEL
        \\ cmp x1, #8
        \\ b.ne 1f
        \\ msr cptr_el2, xzr
        \\1:
        \\ mov x1, #0x300000
        \\ msr cpacr_el1, x1
        // SCTLR_EL1.A makes every data access check its alignment, and an
        // earlier stage may have left it set. Compiled code does not align
        // everything it touches — std.fmt reads its digit-pair table with a
        // two-byte load — so it stays off. SA and SA0 stay as they are: a
        // misaligned stack pointer is a real bug and should still fault.
        \\ mrs x1, sctlr_el1
        \\ mov x2, #2
        \\ bic x1, x1, x2
        \\ msr sctlr_el1, x1
        \\ isb
        // XIP: copy initialized .data from its flash load image into the RAM
        // window, then zero .bss, before any global is read. One byte at a time,
        // which needs nothing enabled and calls nothing.
        \\ adrp x1, _data_lma
        \\ add x1, x1, :lo12:_data_lma
        \\ adrp x2, _data_vma
        \\ add x2, x2, :lo12:_data_vma
        \\ adrp x3, _data_end
        \\ add x3, x3, :lo12:_data_end
        \\2:
        \\ cmp x2, x3
        \\ b.hs 3f
        \\ ldrb w4, [x1], #1
        \\ strb w4, [x2], #1
        \\ b 2b
        \\3:
        \\ adrp x1, __bss_start
        \\ add x1, x1, :lo12:__bss_start
        \\ adrp x2, __bss_end
        \\ add x2, x2, :lo12:__bss_end
        \\4:
        \\ cmp x1, x2
        \\ b.hs 5f
        \\ strb wzr, [x1], #1
        \\ b 4b
        \\5:
        // .bss is clear, so the tree pointer the boot protocol handed us has
        // somewhere to live.
        \\ adrp x1, boot_dtb
        \\ str x19, [x1, :lo12:boot_dtb]
        \\ b arm64Entry
    );
}

/// The device tree the boot stage passed in x0, or 0 if it passed none. The
/// handoff to the OS publishes whichever tree describes this machine: this one
/// when a monitor or bootloader provided it, the build's own otherwise.
export var boot_dtb: usize = 0;

export fn arm64Entry() callconv(.c) noreturn {
    switch (cpu.currentEl()) {
        2 => el.enterEl1(@intFromPtr(&arm64El1)),
        1 => arm64Main(),
        // EL3 means a secure firmware handed over without dropping a level, and
        // EL0 cannot be running this. Both need a real answer we do not have.
        else => cpu.halt(),
    }
}

/// The EL1 continuation. Entered from EL2 with SP_EL1 selected but never set,
/// so it loads the stack before it calls into Zig. It is reached through
/// ELR_EL2, not at reset, so it does not share the reset entry's section: only
/// `_start` may sit in `.text.boot`, which the linker script places first.
export fn arm64El1() callconv(.naked) noreturn {
    asm volatile (
        \\ adrp x0, _stack_top
        \\ add x0, x0, :lo12:_stack_top
        \\ mov sp, x0
        \\ b arm64Main
    );
}

/// The GIC, bound from the tree, and the tick count its timer interrupt drives.
// The EL1 physical timer is a private peripheral interrupt, so the GIC routes it
// per core rather than through the distributor's shared lines.
// zippy:ignore unsafe_undefined
var gic: ?conduit.driver.gicv2.Gicv2 = null;
var ticks: u64 = 0;

export fn arm64Main() callconv(.c) noreturn {
    // The vector table first, so a fault anywhere below reports instead of
    // landing in whatever code sits at the reset vector's offset.
    trap.install();
    // Identity-map flash, the peripheral windows, and RAM, and turn translation
    // on. Everything below this line runs compiled code that loads and stores
    // through pointers it chose, which is not legal on Device memory, and with
    // the MMU off that is all the memory there is.
    mmu.init();
    console.init();

    console.out.writeAll("\nWeir ARM64 bring-up\n") catch {};
    console.out.print("[arm64] running at EL{d}, system counter {d} Hz\n", .{ cpu.currentEl(), timer.frequency() }) catch {};
    console.out.print("[arm64] uart @ {x}, ram @ {x} (+{x}), flash @ {x}\n", .{ soc.uart_base, soc.ram_base, soc.ram_size, soc.flash_base }) catch {};
    console.out.print("[arm64] gic distributor @ {x}, cpu interface @ {x}\n", .{ soc.gic_dist_base, soc.gic_cpu_base }) catch {};

    if (!soc.gic_present) {
        console.out.writeAll("[arm64] no interrupt controller in the tree. Idling.\n") catch {};
        cpu.halt();
    }

    // The machine's own ACPI tables, if the platform hands them over. QEMU's
    // aarch64 virt machine publishes them through fw-cfg exactly as its RISC-V
    // machine does, so the firmware gives the OS a real ACPI set on both.
    if (acpi_qemu.loadTables()) |rsdp| {
        console.out.print("[acpi] using QEMU fw_cfg tables, RSDP @ {x}\n", .{rsdp}) catch {};
    }

    // Boot media, through the same block, filesystem, loader, and boot-manager
    // stack the RISC-V firmware uses: virtio-mmio transports from the tree, GPT,
    // FAT, and a PE image. Interrupts are still masked here, so nothing else
    // writes to the console while the walk reports.
    varstore.init();
    tpm.init();
    const booted: ?pe.Loaded = manager.loadBootImage();

    // The interrupt controller and the timer, before the application runs: a
    // UEFI application may use both, and the firmware's timer services and
    // event pool are built on them.
    gic = conduit.driver.gicv2.bind(
        conduit.Mmio.direct(soc.gic_dist_base),
        conduit.Mmio.direct(soc.gic_cpu_base),
    );
    gic.?.enable(trap.timer_irq);
    trap.irq_handler = onIrq;

    // The EL1 physical timer counts down from its compare value. Re-arming it on
    // every expiry keeps the period independent of how late the handler runs.
    timer.setTimer(timerPeriod());
    timer.enable();
    console.out.print("[arm64] timer armed on IRQ {d}, every {d} counter ticks\n", .{ trap.timer_irq, timerPeriod() }) catch {};

    asm volatile ("msr daifclr, #2"); // unmask IRQ

    startSecondaries();

    if (booted) |loaded| {
        // The UEFI environment: boot and runtime services, the handles the boot
        // manager published, and the tables the OS reads. Its device handle is
        // the ESP, so the application can open its own files.
        const table = uefi.prepare(bootDtb(), 0, loaded.base, loaded.size);
        console.out.print(
            "[uefi] PE entry @ {x} (base {x}, {d} bytes), system table @ {x}\n",
            .{ loaded.entry, loaded.base, loaded.size, table },
        ) catch {};
        // Branch rather than call, with the return address set by hand: the
        // AArch64 binding of the EFI ABI takes the image handle in x0 and the
        // system table in x1, and the application returns to the link register.
        // Nothing compiler-generated is live across the branch, so there is no
        // caller-saved state to preserve and no frame to return through.
        asm volatile (
            \\ mov x0, %[handle]
            \\ mov x1, %[table]
            \\ mov x30, %[after]
            \\ br %[entry]
            :
            : [handle] "r" (@intFromPtr(uefi.imageHandle())),
              [table] "r" (table),
              [entry] "r" (loaded.entry),
              [after] "r" (@intFromPtr(&imageReturned)),
            : .{ .memory = true });
        unreachable;
    }

    console.out.writeAll("[arm64] no bootable image. Counting timer ticks.\n") catch {};
    // Everything below runs with the timer interrupt firing 100 times a second.
    // The vector entry saves and restores the vector registers by hand, so the
    // loop copies a buffer large enough that an interrupt lands inside a copy,
    // and checks the result. A lost vector register shows up here as a mismatch
    // rather than as a mystery later on.
    while (true) contextCheck();
}

/// The tree to publish to the OS: the one this machine booted with when a
/// monitor or bootloader passed it, the build's own otherwise. The build-time
/// tree is what discovery used, so it always describes a machine the firmware
/// can run on; the passed one adds what only the boot stage knows, such as
/// /chosen.
fn bootDtb() usize {
    if (boot_dtb != 0) return boot_dtb;
    const embedded = soc.dtb orelse return 0;
    return @intFromPtr(embedded.ptr);
}

/// The application returned, or called Exit. Either way the firmware is done:
/// the boot manager chose this image and has nothing else to try.
fn imageReturned(status: usize) callconv(.c) noreturn {
    console.out.print(
        "[arm64] the application returned 0x{x}. Halting.\n",
        .{status},
    ) catch {};
    // Stop the tick interrupt too: the firmware has nothing left to do, and a
    // timer that keeps reporting would talk over whatever comes next.
    timer.disable();
    cpu.halt();
}

// --- Secondary cores --------------------------------------------------------

/// Stacks for the cores PSCI starts, one 16 KiB slot each, at the bottom of
/// .bss. The boot core keeps the stack the linker script placed at the top of
/// RAM; these are for the cores that arrive later and need somewhere to run
/// before they have anything else.
const secondary_stack_size = 16 * 1024;
const max_secondaries = 7;
var secondary_stacks: [max_secondaries][secondary_stack_size]u8 align(16) =
    [_][secondary_stack_size]u8{[_]u8{0} ** secondary_stack_size} ** max_secondaries;

/// How many secondary cores have reported in, how many were started, and which
/// ones. The flags exist so the boot core can do the reporting: the console is
/// one UART, and two cores writing it at once interleave into nonsense.
var secondaries_online: u32 = 0;
var secondaries_started: u32 = 0;
var secondary_up: [max_secondaries]bool = [_]bool{false} ** max_secondaries;

/// Start every other core the tree declares, and wait for each to report itself.
///
/// A secondary comes up with an MMU of its own and no stack, so each one runs
/// `secondaryEntry`: it sets up what the boot core set up for itself and then
/// calls `secondaryMain`, which enables translation from the tables the boot
/// core already built.
///
/// PSCI addresses a core by its MPIDR affinity value, which is what a cpu node's
/// `reg` holds, so the targets come from the tree the same way every other
/// platform fact does. The first core is the one already running here, as on
/// RISC-V.
fn startSecondaries() void {
    if (soc.harts.len <= 1) return;
    const want = @min(soc.harts.len - 1, max_secondaries);

    var i: usize = 0;
    while (i < want) : (i += 1) {
        const target = soc.harts[i + 1];
        const stack_base = @intFromPtr(&secondary_stacks[i][0]);
        const status = psci.cpuOn(target, @intFromPtr(&secondaryEntry), stack_base + secondary_stack_size);
        if (status != psci.Success) {
            console.out.print(
                "[arm64] core {d} (affinity {x}): PSCI CPU_ON returned {d}, not started\n",
                .{ i + 1, target, status },
            ) catch {};
            continue;
        }
        secondaries_started += 1;
    }

    // Wait for them, with a bound: a core that never arrives should not hang the
    // boot, and the count says so either way.
    const deadline = timer.now() + timer.frequency() / 2; // half a second
    while (secondaries_online < secondaries_started and timer.now() < deadline) {}
    for (0..want) |j| {
        if (secondary_up[j]) continue;
        console.out.print(
            "[arm64] core {d} (affinity {x}): started but never reported\n",
            .{ j + 1, soc.harts[j + 1] },
        ) catch {};
    }
    console.out.print(
        "[arm64] {d} of {d} secondary cores online\n",
        .{ secondaries_online, secondaries_started },
    ) catch {};
}

/// Entry point PSCI jumps a secondary core to. It arrives with an MMU of its own
/// and no stack, and with x0 holding the context the boot core passed: the top of
/// this core's stack, which becomes SP. Passing an address rather than an index
/// keeps the stack selection on the side that knows the array.
export fn secondaryEntry() callconv(.naked) noreturn {
    asm volatile (
        \\ msr daifset, #0xf
        // The same two things the boot core gives itself first: FP/SIMD, which
        // compiled code assumes, and the alignment check, which compiled code
        // does not satisfy.
        \\ mrs x1, CurrentEL
        \\ cmp x1, #8
        \\ b.ne 1f
        \\ msr cptr_el2, xzr
        \\1:
        \\ mov x1, #0x300000
        \\ msr cpacr_el1, x1
        \\ mrs x1, sctlr_el1
        \\ mov x2, #2
        \\ bic x1, x1, x2
        \\ msr sctlr_el1, x1
        \\ isb
        // This core's stack: the boot core passed its top as the context.
        \\ mov sp, x0
        \\ b secondaryMain
    );
}

/// The second core's Zig entry, also outside `.text.boot` for the same reason as
/// the EL1 continuation: only the reset entry may sit there.
export fn secondaryMain(stack_top: usize) callconv(.c) noreturn {
    // The tables are already built and in memory; this core only has to point at
    // them, which is per-core state rather than shared state.
    mmu.enable();
    trap.install();

    // The stack the core came in on identifies it: the slots are consecutive, so
    // the offset from the first is the index.
    const base = @intFromPtr(&secondary_stacks[0][0]);
    const index: u32 = @intCast((stack_top - base) / secondary_stack_size - 1);
    @atomicStore(bool, &secondary_up[index], true, .release);
    _ = @atomicRmw(u32, &secondaries_online, .Add, 1, .acq_rel);

    // Parked. A core has no work until the OS starts it: the firmware's own use
    // of secondaries is the MP services protocol, which comes later.
    while (true) cpu.wfe();
}

/// The buffer the loop rewrites and copies, and the tally the tick handler
/// reports. A kilobyte is a few hundred vector registers' worth of copying: at
/// 100 interrupts a second, the interrupt lands mid-copy often.
var copy_src: [1024]u8 = undefined; // zippy:ignore unsafe_undefined -- filled before the first copy
var copy_dst: [1024]u8 = undefined; // zippy:ignore unsafe_undefined
var copies: u64 = 0;
var corrupt: u64 = 0;

/// Rewrite `copy_src`, copy it with the compiler's copy path, and compare. The
/// values change every round, so a torn copy is detected rather than matching
/// what was already there. The barrier is what keeps the check in an optimized
/// build: without it the compiler proves the copy faithful and drops the loop.
fn contextCheck() void {
    for (&copy_src, 0..) |*byte, i| byte.* = @truncate(i *% 7 +% copies);
    @memcpy(&copy_dst, &copy_src);
    copies += 1;
    if (!std.mem.eql(u8, &copy_dst, &copy_src)) corrupt += 1;
    std.mem.doNotOptimizeAway(&copy_dst);
}

/// 10 ms of system counter, the tick period this bring-up runs at.
fn timerPeriod() u64 {
    return timer.frequency() / 100;
}

/// The interrupt handler the vector table calls. Claims the interrupt from the
/// GIC, services it, and completes it so the line drops.
fn onIrq() callconv(.c) void {
    const g = gic orelse return;
    const irq = g.claim() orelse return;
    if (irq == trap.timer_irq) {
        ticks += 1;
        timer.setTimer(timerPeriod());
        // Once a second at this period: frequent enough to prove the timer
        // keeps firing, quiet enough to read.
        if (ticks % 100 == 0)
            console.out.print(
                "[arm64] {d} timer ticks, {d} ms, {d} copies, {d} corrupt\n",
                .{ ticks, ticks * 10, copies, corrupt },
            ) catch {};
    }
    g.complete(irq);
}
