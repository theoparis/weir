//! ACPI tables for an AArch64 board: the GIC records the MADT carries, the
//! architectured timer's GTDT, and the console's SPCR.
//!
//! The plumbing — FADT, DSDT, XSDT, RSDP, checksums — is arch-neutral and lives
//! in acpi.zig. What an OS reads differently on AArch64 is the interrupt
//! controller (a GIC, not a PLIC), the timer (the architectured counter, not a
//! CLINT), and the console (a PL011, not a 16550). Each body here follows the
//! layout QEMU publishes for its aarch64 `virt` machine, the shape an OS on this
//! platform is known to accept, and takes its addresses and interrupts from the
//! device tree: soc.zig resolved them at compile time.
//!
//! RISC-V describes the same three things with RINTC and PLIC records, an RHCT,
//! and a 16550 SPCR; an OS reads one set or the other, never both.

const std = @import("std");
const almanac = @import("conduit").almanac;

const Gicc = almanac.tables.madt.Gicc;
const Gicd = almanac.tables.madt.Gicd;

/// MADT revision 4 (ACPI 5.0) is the first that defines the GIC structures.
pub const apic_revision: u8 = 4;
/// GTDT revision 3 is what QEMU publishes for this platform.
pub const gtdt_revision: u8 = 3;
/// SPCR revision 2 carries the GIC interrupt fields an ARM console needs.
pub const spcr_revision: u8 = 2;

/// MADT body length: the 8-byte fixed part, the distributor, and one CPU
/// interface per core. The table on the wire adds its 36-byte header.
pub fn madtBodyLen(cores: usize) usize {
    return 8 + @sizeOf(Gicd) + cores * @sizeOf(Gicc);
}

/// GTDT body length: one counter control base, four timer (GSIV, flags) pairs,
/// and the platform-timer list. The 104-byte table is 36 bytes longer.
pub const gtdtBodyLen: usize = 68;

/// SPCR body length: the console's GAS, its GSI, and its line settings. The
/// 80-byte table is 36 bytes longer.
pub const spcrBodyLen: usize = 44;

/// Timer flags: bit 0 trigger mode (0 level), bit 1 polarity (0 active high),
/// bit 2 always-on. The architectured counter keeps counting in low-power states.
const timer_flags: u32 = 4;

/// Which of the timer node's four interrupts is which. The device tree lists
/// them in the architectured order (secure EL1, non-secure EL1, virtual EL1,
/// non-secure EL2) and soc.zig lowered each into a GSI; the GTDT publishes only
/// the non-secure ones, because those are the ones an OS at EL1 can take.
const timer_nonsecure_el1 = 1;
const timer_virtual_el1 = 2;
const timer_nonsecure_el2 = 3;

/// The MADT body (everything after the 36-byte table header): the GIC
/// distributor and a CPU interface per core. `mpidrs` holds each core's MPIDR
/// affinity, the value an OS matches a CPU against; `gicd` and `gicc` are the
/// distributor's and the CPU interface's MMIO windows, from the tree. The OS
/// takes its CPUs and its interrupt controller from here, so both must agree
/// with the hardware.
pub fn madtBody(buf: []u8, mpidrs: []const u64, gicd: u64, gicc: u64) []const u8 {
    std.debug.assert(buf.len >= madtBodyLen(mpidrs.len));
    @memset(buf, 0);
    // The fixed part stays zero: AArch64 has no 8259 and no I/O APIC, so there
    // is no local interrupt controller address and no PCAT flag to set.
    const dist = Gicd{
        .type = 0x0c,
        .length = @sizeOf(Gicd),
        .reserved0 = 0,
        .gic_id = 0,
        .physical_base_address = gicd,
        .system_vector_base = 0,
        // soc.zig matches GICv2 compatibles only, and the memory-mapped CPU
        // interface below says the same thing: a GICv3 has redistributors.
        .gic_version = 2,
        .reserved1 = .{ 0, 0, 0 },
    };
    @memcpy(buf[8..][0..@sizeOf(Gicd)], std.mem.asBytes(&dist));

    var off: usize = 8 + @sizeOf(Gicd);
    for (mpidrs, 0..) |mpidr, i| {
        const iface = Gicc{
            .type = 0x0b,
            .length = @sizeOf(Gicc),
            .reserved0 = 0,
            .cpu_interface_number = @intCast(i),
            .acpi_processor_uid = @intCast(i),
            .flags = 1, // enabled: the firmware brings every core it names online
            .parking_protocol_version = 0,
            // The firmware does not enable the PMU. A GSIV here would name an
            // interrupt the OS has to wire itself, and it can do that without
            // the firmware having promised it.
            .performance_interrupt_gsiv = 0,
            .parked_address = 0,
            .physical_base_address = gicc,
            // A GICv2 CPU interface is memory-mapped. There is no virtual
            // interface (that needs EL2 support this firmware does not give an
            // OS) and no redistributor to describe.
            .gicv = 0,
            .gich = 0,
            .vgic_maintenance_interrupt = 0,
            .gicr_base_address = 0,
            .mpidr = mpidr,
            .processor_power_efficiency_class = 0,
            .reserved1 = 0,
            .spe_overflow_interrupt = 0,
        };
        @memcpy(buf[off..][0..@sizeOf(Gicc)], std.mem.asBytes(&iface));
        off += @sizeOf(Gicc);
    }
    return buf[0..off];
}

/// The GTDT body: the architectured timer's interrupts. `gsivs` is the timer
/// node's four interrupts as GSIs (soc.timer_gsivs), in the order the tree names
/// them.
pub fn gtdtBody(buf: *[gtdtBodyLen]u8, gsivs: [4]u32) []const u8 {
    @memset(buf, 0);
    // No memory-mapped counter control base: the counter is programmed through
    // the system registers alone, so the field says "none".
    std.mem.writeInt(u64, buf[0..8], std.math.maxInt(u64), .little);
    // A secure EL1 timer would need an EL3 the firmware does not run, and a
    // virtual EL2 timer would need an EL2 the OS does not get. Both fields stay
    // zero, which is how the GTDT says a timer is not available.
    writeTimer(buf, 12, 0, 0);
    writeTimer(buf, 20, gsivs[timer_nonsecure_el1], timer_flags);
    writeTimer(buf, 28, gsivs[timer_virtual_el1], 0);
    writeTimer(buf, 36, gsivs[timer_nonsecure_el2], 0);
    writeTimer(buf, 44, 0, 0);
    // Platform timer count (offset 52) and offset (56) stay zero: an OS needs
    // the architectured timer here, and the firmware publishes no memory-mapped
    // timer for it to fall back to.
    return buf;
}

fn writeTimer(buf: *[gtdtBodyLen]u8, off: usize, gsiv: u32, flags: u32) void {
    std.mem.writeInt(u32, buf[off..][0..4], gsiv, .little);
    std.mem.writeInt(u32, buf[off + 4 ..][0..4], flags, .little);
}

/// SPCR interface type: an ARM PL011, whose register map is not a 16550's.
pub const interface_pl011: u8 = 3;
/// SPCR interface type: a 16550, or a subset of one.
pub const interface_16550: u8 = 0;

/// SPCR interrupt type 8: the console's interrupt comes from a GIC.
const interrupt_gic: u8 = 8;
/// Baud rate 7: 115200. The SPCR states the rate the console runs at.
const baud_115200: u8 = 7;

/// The SPCR body: the console's MMIO window, its GSI, and its line settings.
/// `interface` selects the register-map family (see the two constants above).
pub fn spcrBody(buf: *[spcrBodyLen]u8, uart: u64, gsi: u32, interface: u8) []const u8 {
    @memset(buf, 0);
    buf[0] = interface;
    // The 12-byte GAS: a register window in system memory, 32 bits wide, read
    // a dword at a time (a PL011 register is 32 bits; a 16550's are bytes, but
    // the console carries no FIFO path that would care).
    buf[4] = 0; // address space: system memory
    buf[5] = 32; // register bit width
    buf[6] = 0; // register bit offset
    buf[7] = 3; // access size: dword
    std.mem.writeInt(u64, buf[8..16], uart, .little);
    buf[16] = interrupt_gic;
    buf[17] = 0; // legacy IRQ: unused, the GSI below is what the OS binds
    std.mem.writeInt(u32, buf[18..22], gsi, .little);
    buf[22] = baud_115200;
    buf[23] = 0; // parity: none
    buf[24] = 1; // stop bits: 1
    buf[25] = 0; // flow control: none
    // Terminal type, language, and the PCI fields stay zero, except the two ids
    // that mean "not a PCI device".
    std.mem.writeInt(u16, buf[28..30], 0xFFFF, .little);
    std.mem.writeInt(u16, buf[30..32], 0xFFFF, .little);
    return buf;
}
