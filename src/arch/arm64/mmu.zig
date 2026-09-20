//! Stage-1 identity map.
//!
//! With the MMU off, AArch64 treats every access as Device-nGnRnE, and Device
//! memory has no unaligned accesses at all: any load or store wider than a byte
//! from an unaligned address faults. That is exactly what compiled code does
//! without meaning to (std.fmt reads its digit-pair table with a two-byte load,
//! and Zig turns a copy of any aggregate over 16 bytes into a SIMD loop), so a
//! firmware that runs with the MMU off faults inside code it did not write.
//! Nothing is cached either: every instruction fetch and stack access goes to
//! the bus.
//!
//! The firmware therefore builds an identity map and turns the MMU on before it
//! runs code that does not control its own alignment. Two levels with 2 MiB
//! blocks is enough: the image's flash window, the peripheral windows, and RAM
//! need three distinct attribute combinations, and the tables fit in .bss.
//!
//! The map is deliberately partial. An address outside the three regions below
//! is left unmapped, so a wild pointer takes a translation fault instead of
//! silently reaching a peripheral.
//!
//!   * 0x0000_0000 + 64 MiB  pflash0, where -bios places this image. Normal,
//!                           read-only at EL1, executable.
//!   * 0x0400_0000 + 960 MiB everything up to RAM: the GIC, the UART, the RTC,
//!                           fw-cfg, the virtio-mmio transports, and the PCIe
//!                           ECAM window. Device.
//!   * 0x4000_0000 + 2 GiB   RAM. Normal, writable, executable.

const sysreg = @import("sysreg.zig");

const entries_per_table = 512;
/// A level 2 block, so a level 1 entry covers 1 GiB and the tables stay small.
const block_size = 2 << 20;
const gib = 1 << 30;
/// Slots 0..3, i.e. 0x0..0xc000_0000: the flash, the peripheral windows, and
/// the 2 GiB of RAM QEMU's virt machine places at 0x4000_0000.
const mapped_slots = 3;

/// The first-level table TTBR0_EL1 points at, and one second-level table per
/// 1 GiB slot. Both live in .bss, which the reset path has already cleared.
var l1_table: [entries_per_table]u64 align(4096) = [_]u64{0} ** entries_per_table;
var l2_tables: [mapped_slots][entries_per_table]u64 align(4096) =
    [_][entries_per_table]u64{[_]u64{0} ** entries_per_table} ** mapped_slots;

const Kind = enum { flash, ram, device };

// Descriptor bits[1:0] select the kind of entry, and the two kinds that matter
// here are easy to confuse: 0b11 is a table (or, at the last level, a page), and
// 0b01 is a block. Writing 0b11 for a 2 MiB block sends the walker to a level 3
// table that does not exist, and every access then takes a level 3 translation
// fault.
const descriptor_table_or_page = 0b11;
const descriptor_block = 0b01;
const descriptor_af = 1 << 10; // Access Flag: without it every access faults.
const descriptor_pxn = 1 << 53;
const descriptor_uxn = 1 << 54;

// MAIR_EL1 attribute indices. Index 0 is Normal write-back with read and write
// allocation both ways; index 1 is Device-nGnRnE, the strictest device type,
// which is what a register window wants.
const attr_normal: u64 = 0;
const attr_device: u64 = 1;
const mair_el1: u64 = 0xff | (0x00 << 8);

// TCR_EL1. One field per line, at the bit position the architecture gives it.
// 39-bit VA, 4 KiB granule, inner-shareable write-back page walks for both
// halves, and a 40-bit physical address space.
const t0sz = 25; // bits [5:0]
const irgn0 = 0b01 << 8; // [9:8] write-back
const orgn0 = 0b01 << 10; // [11:10] write-back
const sh0 = 0b11 << 12; // [13:12] inner shareable
const tg0 = 0b00 << 14; // [15:14] 4 KiB
const t1sz = @as(u64, t0sz) << 16; // [21:16]
// EPD1 (bit 23) stops TTBR1 walks: the map is identity in the low half only, so
// a high-half address should fault rather than walk a table never built.
const epd1 = 1 << 23;
const irgn1 = 0b01 << 24; // [25:24]
const orgn1 = 0b01 << 26; // [27:26]
const sh1 = 0b11 << 28; // [29:28]
const tg1 = 0b10 << 30; // [31:30] 4 KiB
const ips = 0b010 << 32; // [34:32] 40-bit physical addresses
const tcr_el1: u64 = t0sz | irgn0 | orgn0 | sh0 | tg0 | t1sz | epd1 | irgn1 | orgn1 | sh1 | tg1 | ips;

// SCTLR_EL1 bits to turn on: the MMU, the data cache, and the instruction cache.
const sctlr_m = 1 << 0;
const sctlr_c = 1 << 2;
const sctlr_i = 1 << 12;

/// Build the tables and enable translation. Call once, from EL1, before any
/// code that reads or writes through a pointer it did not align itself.
///
/// Nothing in `buildTables` may copy an aggregate. The compiler turns such a
/// copy into a SIMD loop, and a SIMD access to unaligned memory is a fault until
/// this function has done its job, so the three regions are three explicit calls
/// rather than an array of structs to iterate over.
pub fn init() void {
    buildTables();
    enable();
}

/// Fill the tables. The boot core does this once, before any core is running on
/// them; a secondary core inherits the result and only calls `enable`.
pub fn buildTables() void {
    inline for (0..mapped_slots) |slot| {
        l1_table[slot] = @intFromPtr(&l2_tables[slot]) | descriptor_table_or_page;
    }
    fill(0x0000_0000, 0x0400_0000, .flash);
    fill(0x0400_0000, 0x3c00_0000, .device);
    fill(0x4000_0000, 0x8000_0000, .ram);
}

/// Point this core at the tables and turn translation on. The registers are all
/// per-core, so every core that comes up runs this for itself.
pub fn enable() void {
    sysreg.write("MAIR_EL1", mair_el1);
    sysreg.write("TCR_EL1", tcr_el1);
    sysreg.write("TTBR0_EL1", @intFromPtr(&l1_table));
    sysreg.write("TTBR1_EL1", 0);
    asm volatile ("dsb sy");
    asm volatile ("isb");

    sysreg.set("SCTLR_EL1", sctlr_m | sctlr_c | sctlr_i);
    // The tables and the registers above have to be visible to the walker
    // before it can be trusted, and any translation cached while they were being
    // written has to go.
    asm volatile ("dsb sy");
    asm volatile ("isb");
    asm volatile ("tlbi vmalle1");
    asm volatile ("dsb sy");
    asm volatile ("isb");
}

fn fill(base: u64, size: u64, kind: Kind) void {
    var addr = base;
    const end = base + size;
    while (addr < end) : (addr += block_size) {
        const slot = addr / gib;
        const index = (addr % gib) / block_size;
        l2_tables[slot][index] = blockDescriptor(addr, kind);
    }
}

fn blockDescriptor(addr: u64, kind: Kind) u64 {
    const base = addr & ~@as(u64, block_size - 1);
    var d = descriptor_block | descriptor_af | base;
    d |= @as(u64, switch (kind) {
        .flash, .ram => attr_normal,
        .device => attr_device,
    }) << 2;
    switch (kind) {
        // AP[2:1] = 0b10: read-only at EL1.
        .flash => d |= 0b10 << 6,
        // SH = 0b11 (inner shareable) for cacheable memory.
        .ram => d |= 0b11 << 8,
        // Peripheral registers are never instructions and never user-accessible.
        .device => d |= descriptor_pxn | descriptor_uxn,
    }
    return d;
}
