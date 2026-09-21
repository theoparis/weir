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

// --- Tests ------------------------------------------------------------------
//
// The bodies are what an OS reads off the wire, so the tests pin the layouts:
// a field written at the wrong offset, or a record of the wrong length, reads
// back wrong here rather than in the OS. The host builds this file with a host
// conduit, the way it builds src/acpi/madt.zig.

const testing = std.testing;

test "GTDT: the architectured timer list, at the offsets an OS reads" {
    var buf: [gtdtBodyLen]u8 = undefined;
    const body = gtdtBody(&buf, .{ 29, 30, 27, 26 });
    try testing.expectEqual(gtdtBodyLen, body.len);

    // No memory-mapped counter control base: the counter is system registers.
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), std.mem.readInt(u64, body[0..8], .little));
    // No secure EL1 timer: the firmware runs no EL3, so the entry is zero even
    // though the tree names one.
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, body[12..16], .little));
    // Non-secure EL1, with the level/active-high/always-on flags.
    try testing.expectEqual(@as(u32, 30), std.mem.readInt(u32, body[20..24], .little));
    try testing.expectEqual(@as(u32, timer_flags), std.mem.readInt(u32, body[24..28], .little));
    // Virtual EL1 and non-secure EL2, from the same tree node.
    try testing.expectEqual(@as(u32, 27), std.mem.readInt(u32, body[28..32], .little));
    try testing.expectEqual(@as(u32, 26), std.mem.readInt(u32, body[36..40], .little));
    // No virtual EL2 timer (the OS gets no EL2), and no platform timers.
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, body[44..48], .little));
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, body[52..56], .little));
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, body[56..60], .little));

    // And through the accessors an OS uses, on a complete table.
    var table: [36 + gtdtBodyLen]u8 = [_]u8{0} ** (36 + gtdtBodyLen);
    @memcpy(table[0..4], "GTDT");
    std.mem.writeInt(u32, table[4..8], table.len, .little);
    @memcpy(table[36..], body);
    const parsed = try almanac.tables.Gtdt.fromBytes(&table);
    try testing.expectEqual(@as(u32, 30), parsed.nonSecureEl1Gsiv());
    try testing.expectEqual(@as(u32, 27), parsed.virtualEl1Gsiv());
}

test "SPCR: a memory-mapped console that interrupts through the GIC" {
    var buf: [spcrBodyLen]u8 = undefined;
    const body = spcrBody(&buf, 0x0900_0000, 33, interface_pl011);
    try testing.expectEqual(spcrBodyLen, body.len);

    try testing.expectEqual(interface_pl011, body[0]);
    // The GAS: a 32-bit register window in system memory, read a dword at a time.
    try testing.expectEqual(@as(u8, 0), body[4]); // system memory
    try testing.expectEqual(@as(u8, 32), body[5]); // register bit width
    try testing.expectEqual(@as(u8, 3), body[7]); // dword access
    try testing.expectEqual(@as(u64, 0x0900_0000), std.mem.readInt(u64, body[8..16], .little));
    try testing.expectEqual(interrupt_gic, body[16]);
    try testing.expectEqual(@as(u32, 33), std.mem.readInt(u32, body[18..22], .little));
    try testing.expectEqual(baud_115200, body[22]);
    try testing.expectEqual(@as(u8, 1), body[24]); // one stop bit
    try testing.expectEqual(@as(u16, 0xFFFF), std.mem.readInt(u16, body[28..30], .little));
    try testing.expectEqual(@as(u16, 0xFFFF), std.mem.readInt(u16, body[30..32], .little));

    var table: [36 + spcrBodyLen]u8 = [_]u8{0} ** (36 + spcrBodyLen);
    @memcpy(table[0..4], "SPCR");
    std.mem.writeInt(u32, table[4..8], table.len, .little);
    @memcpy(table[36..], body);
    const parsed = try almanac.tables.Spcr.fromBytes(&table);
    try testing.expectEqual(almanac.tables.spcr.InterfaceType.arm_pl011, parsed.interfaceType());
    try testing.expectEqual(@as(u64, 0x0900_0000), parsed.baseAddress().address);
    try testing.expectEqual(@as(u32, 33), parsed.globalSystemInterrupt());
}

test "MADT: one distributor and a CPU interface per core" {
    const mpidrs = [_]u64{ 0x0, 0x1 };
    var buf: [madtBodyLen(mpidrs.len)]u8 = undefined;
    const body = madtBody(&buf, &mpidrs, 0x0800_0000, 0x0801_0000);
    try testing.expectEqual(madtBodyLen(mpidrs.len), body.len);
    // The fixed part is zero: AArch64 has no local APIC and no PCAT flag.
    try testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, body[0..8], .little));
    // The distributor, first, as an OS walks the records in order.
    try testing.expectEqual(@as(u8, 0x0c), body[8]);
    try testing.expectEqual(@as(u8, @sizeOf(Gicd)), body[9]);
    try testing.expectEqual(@as(u8, 2), body[8 + @offsetOf(Gicd, "gic_version")]);
    try testing.expectEqual(
        @as(u64, 0x0800_0000),
        std.mem.readInt(u64, body[8 + @offsetOf(Gicd, "physical_base_address") ..][0..8], .little),
    );
    // Then a CPU interface per core, carrying the core's affinity.
    const gicc = 8 + @sizeOf(Gicd);
    try testing.expectEqual(@as(u8, 0x0b), body[gicc]);
    try testing.expectEqual(@as(u8, @sizeOf(Gicc)), body[gicc + 1]);
    for (mpidrs, 0..) |mpidr, i| {
        const rec = gicc + i * @sizeOf(Gicc);
        try testing.expectEqual(@as(u32, @intCast(i)), std.mem.readInt(u32, body[rec + 4 ..][0..4], .little));
        try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, body[rec + 12 ..][0..4], .little));
        try testing.expectEqual(@as(u64, 0x0801_0000), std.mem.readInt(u64, body[rec + 32 ..][0..8], .little));
        try testing.expectEqual(mpidr, std.mem.readInt(u64, body[rec + 68 ..][0..8], .little));
    }

    // The iterator an OS uses finds both records, with those bases.
    var table: [36 + madtBodyLen(mpidrs.len)]u8 = [_]u8{0} ** (36 + madtBodyLen(mpidrs.len));
    @memcpy(table[0..4], "APIC");
    std.mem.writeInt(u32, table[4..8], table.len, .little);
    @memcpy(table[36..], body);
    const parsed = try almanac.tables.Madt.fromBytes(&table);
    var cores: usize = 0;
    var dist: u64 = 0;
    var it = parsed.iterator();
    while (try it.next()) |entry| switch (entry) {
        .gicd => |d| dist = d.physical_base_address,
        .gicc => cores += 1,
        else => {},
    };
    try testing.expectEqual(@as(u64, 0x0800_0000), dist);
    try testing.expectEqual(mpidrs.len, cores);
}
