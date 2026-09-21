//! ACPI table construction. The platform supplies the DSDT (raw AML) through
//! `-Daml`. Weir wraps it in the minimum HW-reduced RISC-V table set
//! (RSDP -> XSDT -> FADT, with FADT.X_DSDT pointing at the AML in place).
//! almanac's Builder lays the tables into the ACPI-reclaim pool and stamps every
//! checksum. The tables MUST sit in that pool (see mem.zig / qemu.zig): the EFI
//! memory map marks it EfiACPIReclaimMemory, so the OS maps and reads the tables.
//! Tables left in reserved firmware memory fault the OS's ACPI table setup
//! (Linux acpi_tb_init_table_descriptor) while it reads each table header.

const std = @import("std");
const builtin = @import("builtin");
const almanac = @import("conduit").almanac;
const console = @import("../console/console.zig");
const soc = @import("soc");
const qemu = @import("qemu.zig");
const aml = @import("aml.zig");
const madt = @import("madt.zig");
const arm = @import("arm64.zig");
const conduit = @import("conduit");

/// Build the table set referencing `dsdt` (raw AML) and report a summary. No
/// paging here, so virtual == physical and the pool base is a plain address.
pub fn setup(dsdt: ?[]const u8) void {
    build(dsdt) catch {
        console.err.writeAll("[acpi] table construction failed (buffer too small)\n") catch {};
    };
}

/// SPCR body (after the 36-byte SDT header): a full-16550 console at `uart_base`,
/// byte-wide registers, 115200 8N1, polled.
fn spcrBody(uart_base: u64) [44]u8 {
    var b = [_]u8{0} ** 44;
    b[0] = 0x00; // interface type: full 16550
    b[4] = 0x00; // base address GAS: system memory
    b[5] = 8; // register bit width
    b[7] = 1; // access size: byte
    std.mem.writeInt(u64, b[8..16], uart_base, .little);
    b[22] = 7; // baud rate: 115200
    b[24] = 1; // stop bits: 1
    std.mem.writeInt(u16, b[28..30], 0xFFFF, .little); // not a PCI device
    std.mem.writeInt(u16, b[30..32], 0xFFFF, .little); // not a PCI vendor
    return b;
}

// The PLIC's ACPI identity. One PLIC exists on every River SoC today, so it is
// PLIC 0 and it owns the global system interrupts from 0 up. `plic_gsi_base`
// must equal the `_GSB` the DSDT gives the same PLIC (see buildDsdt below): an
// OS matches the two to attach the MADT record to the DSDT device, and without
// a match it never probes the PLIC at all.
const plic_id: u8 = 0;
const plic_gsi_base: u32 = 0;

// Highest priority the Harbor PLIC accepts. It has 3 priority bits, and the
// device tree has no property for it, so it is stated here.
const plic_max_priority: u16 = 7;

// The PLIC's hardware ID, the same string as the DSDT device's _HID. The field
// is informational and no OS driver reads it, but a value is more use than zero
// to anyone dumping the table.
const plic_hw_id = "RSCV0001".*;

// The contexts the PLIC declares, in the layout the MADT builder wants.
const plic_contexts_arr: [soc.plic_contexts.len]madt.Context = blk: {
    var arr: [soc.plic_contexts.len]madt.Context = undefined;
    for (soc.plic_contexts, 0..) |c, i| arr[i] = .{ .hart_id = c.hart_id, .cause = c.cause };
    break :blk arr;
};

// One RINTC per hart, each naming the PLIC context that drives that hart's
// supervisor external interrupt. Weir owns the machine context, so it is never
// named here. Both the hart list and the context list come from the device
// tree, so they describe the interrupt wiring the SoC really has.
const madt_harts: [soc.hart_count]madt.Hart = blk: {
    var arr: [soc.hart_count]madt.Hart = undefined;
    for (soc.harts, 0..) |hart, i| arr[i] = .{
        .hart_id = hart,
        .uid = @intCast(i),
        .context = madt.supervisorContext(&plic_contexts_arr, hart),
    };
    break :blk arr;
};

var madt_buf: [madt.bodyLen(soc.hart_count)]u8 = undefined;

fn madtBody() []const u8 {
    return madt.build(&madt_buf, &madt_harts, .{
        .id = plic_id,
        .hw_id = plic_hw_id,
        .num_irqs = @intCast(soc.plic_ndev),
        .max_priority = plic_max_priority,
        .size = @intCast(soc.plic_size),
        .base = soc.plic_base,
        .gsi_base = plic_gsi_base,
    });
}

/// Build the RHCT body into `buf`: the hart timebase, then an ISA-string node,
/// an MMU node (the paging scheme the OS needs before it can enable paging), and
/// a hart-info node referencing both. Node offsets are relative to the table
/// start (header + 20 = 56). Returns the used bytes (variable ISA length).
fn buildRhct(buf: []u8, timebase: u64, isa: []const u8, mmu_type: u8) []const u8 {
    @memset(buf, 0);
    // buf[0..4] flags: 0.
    std.mem.writeInt(u64, buf[4..12], timebase, .little); // time base frequency
    std.mem.writeInt(u32, buf[12..16], 3, .little); // node count: ISA, MMU, hart info
    std.mem.writeInt(u32, buf[16..20], 56, .little); // offset of the first node
    // ISA string node (type 0) at body offset 20 (table offset 56).
    const isa_len = isa.len + 1; // include the null terminator
    const isa_node = (8 + isa_len + 1) & ~@as(usize, 1); // pad to 2 bytes
    std.mem.writeInt(u16, buf[20..22], 0, .little); // node type: ISA string
    std.mem.writeInt(u16, buf[22..24], @intCast(isa_node), .little);
    std.mem.writeInt(u16, buf[24..26], 1, .little); // revision
    std.mem.writeInt(u16, buf[26..28], @intCast(isa_len), .little); // ISA length
    @memcpy(buf[28..][0..isa.len], isa);
    // MMU node (type 2) after the ISA node.
    const m = 20 + isa_node; // body offset
    std.mem.writeInt(u16, buf[m..][0..2], 2, .little); // node type: MMU
    std.mem.writeInt(u16, buf[m + 2 ..][0..2], 8, .little); // node length
    std.mem.writeInt(u16, buf[m + 4 ..][0..2], 1, .little); // revision
    buf[m + 6] = 0; // reserved
    buf[m + 7] = mmu_type; // 0 = Sv39, 1 = Sv48, 2 = Sv57
    // Hart info node (type 0xFFFF) after the MMU node, referencing ISA and MMU.
    const h = m + 8;
    std.mem.writeInt(u16, buf[h..][0..2], 0xFFFF, .little); // node type: hart info
    std.mem.writeInt(u16, buf[h + 2 ..][0..2], 20, .little); // node length (12 + 2*4)
    std.mem.writeInt(u16, buf[h + 4 ..][0..2], 1, .little); // revision
    std.mem.writeInt(u16, buf[h + 6 ..][0..2], 2, .little); // number of offsets
    std.mem.writeInt(u32, buf[h + 8 ..][0..4], 0, .little); // ACPI processor UID
    std.mem.writeInt(u32, buf[h + 12 ..][0..4], 56, .little); // table offset of ISA node
    std.mem.writeInt(u32, buf[h + 16 ..][0..4], @intCast(36 + m), .little); // MMU node
    return buf[0 .. h + 20];
}

// Backing storage for the translated device list, filled from soc.devices and
// consumed by buildScope within the same call. Module-level to keep it off the
// stack. The DSDT AML body lands in dsdt_body.
const max_dsdt_devs = 24;
var dsdt_devs: [max_dsdt_devs]aml.Device = undefined;
var dsdt_mem: [max_dsdt_devs][4]aml.MemRegion = undefined;
var dsdt_irqs: [max_dsdt_devs][8]u32 = undefined;
var dsdt_props: [max_dsdt_devs][2]aml.Prop = undefined;
var dsdt_body: [8192]u8 = undefined;

fn digit(v: usize) u8 {
    return '0' + @as(u8, @intCast(v % 10));
}

/// The interrupt controller's ACPI HID, or null when the DSDT must not carry the
/// device at all.
///
/// On RISC-V the controller is a PLIC (RSCV0001) or an APLIC (RSCV0002), and its
/// native HID plus a _GSB is what registers the irqchip. An AArch64 GIC has no
/// such HID: an OS binds it from the MADT's GIC records, so the controller is
/// left out of the DSDT — a RISC-V HID there would mislabel it.
fn intcHid(m: *const conduit.Match) ?[]const u8 {
    if (builtin.cpu.arch == .aarch64) return null;
    for (m.ids.slice()) |id| {
        if (std.mem.indexOf(u8, id, "aplic") != null) return "RSCV0002"; // APLIC
    }
    return "RSCV0001"; // PLIC
}

/// The console UART's ACPI HID: the one an OS's driver matches.
///
/// RISC-V uses RSCV0003, which the kernel's 8250 ACPI driver binds (it reads the
/// baud clock from _DSD). AArch64 uses the architected HIDs: ARMH0011 for a
/// PL011, PNP0501 for a 16550-compatible part. The PRP0001 device-tree bridge
/// binds none of these.
fn uartHid(m: *const conduit.Match, comptime is_arm: bool) []const u8 {
    if (!is_arm) return "RSCV0003";
    for (m.ids.slice()) |id| {
        if (std.mem.indexOf(u8, id, "pl011") != null) return "ARMH0011";
    }
    return "PNP0501";
}

/// Add a clock-frequency property from the node's clock, if it has one.
fn addClock(m: *const conduit.Match, props: *[2]aml.Prop, pi: *usize) void {
    if (m.clock()) |c| if (c.freq_hz) |hz| {
        props[pi.*] = .{ .key = "clock-frequency", .value = .{ .int = hz } };
        pi.* += 1;
    };
}

/// Add every interrupt (GSI) the node declares to its _CRS. conduit's Irq.number
/// is already the GSI an OS binds: the PLIC's source on RISC-V, and the GIC's
/// type-offset interrupt ID on AArch64.
fn addIrqs(m: *const conduit.Match, irqs: *[8]u32) usize {
    var qi: usize = 0;
    while (qi < irqs.len) : (qi += 1) {
        const q = m.irq(qi) orelse break;
        irqs[qi] = q.number;
    }
    return qi;
}

/// Translate the device tree into the DSDT AML body when the platform supplies
/// none. Well-known devices use their native ACPI HID so the kernel binds them
/// directly — the interrupt controller (see `intcHid`) and the console UART (see
/// `uartHid`) — and every other node becomes a PRP0001 device whose driver
/// matches the _DSD "compatible" property, the device-tree bridge. conduit has
/// already resolved each node's resources and compatible ids (soc.devices).
///
/// `is_arm` selects the AArch64 HIDs and leaves the interrupt controller out; the
/// rest of the walk is the same on both.
fn buildDsdt(comptime is_arm: bool) []u8 {
    var n: usize = 0;
    for ([_]conduit.Class{ .intc, .uart, .block }) |class| {
        var it = conduit.discover.ofClass(soc.devices, class);
        while (it.next()) |m| {
            if (n >= max_dsdt_devs) break;

            var mi: usize = 0;
            while (mi < dsdt_mem[n].len) : (mi += 1) {
                const r = m.mmioAt(mi) orelse break;
                dsdt_mem[n][mi] = .{ .base = @intCast(r.base), .size = @intCast(r.size) };
            }

            var qi: usize = 0;
            var pi: usize = 0;
            var hid: []const u8 = "PRP0001";
            var gsb: ?u32 = null;
            switch (class) {
                // The interrupt controller: source of interrupts, no _DSD. Its
                // native HID + _GSB is what registers the irqchip. A GIC has
                // neither, and the MADT already describes it.
                .intc => {
                    hid = intcHid(m) orelse continue;
                    gsb = plic_gsi_base;
                },
                // The console UART, under the HID its driver matches.
                .uart => {
                    hid = uartHid(m, is_arm);
                    qi = addIrqs(m, &dsdt_irqs[n]);
                    addClock(m, &dsdt_props[n], &pi);
                },
                // Everything else: the PRP0001 device-tree bridge.
                else => {
                    qi = addIrqs(m, &dsdt_irqs[n]);
                    dsdt_props[n][pi] = .{ .key = "compatible", .value = .{ .strs = m.ids.slice() } };
                    pi += 1;
                    addClock(m, &dsdt_props[n], &pi);
                },
            }

            dsdt_devs[n] = .{
                .name = .{ 'D', digit(n / 100), digit(n / 10), digit(n) },
                .uid = @intCast(n),
                .hid = hid,
                .gsb = gsb,
                .mem = dsdt_mem[n][0..mi],
                .irqs = dsdt_irqs[n][0..qi],
                .props = dsdt_props[n][0..pi],
            };
            n += 1;
        }
    }
    return aml.buildScope(&dsdt_body, dsdt_devs[0..n]);
}

/// A builder laying tables into the ACPI-reclaim pool, not a static buffer, so
/// the OS maps and reads them. See the file header.
fn newBuilder() almanac.Builder {
    const pool: [*]u8 = @ptrFromInt(qemu.POOL_BASE);
    var b = almanac.Builder.init(pool[0..qemu.POOL_SIZE], qemu.POOL_BASE);
    b.oem_id = "LILSMI".*;
    b.oem_table_id = "WEIR    ".*;
    b.creator_id = "WEIR".*;
    return b;
}

/// The DSDT the FADT will name: the provided AML copied into the pool, or the
/// device tree translated.
///
/// The embedded blob lives in reserved firmware rodata, which the OS cannot map
/// for ACPI; the pool is EfiACPIReclaimMemory. ACPICA (acpi_tb_parse_fadt)
/// always installs the DSDT the FADT names and reads its header, so the FADT
/// must point at a real, backed table. With no AML, translate the device tree
/// into the DSDT: without device objects the OS enumerates nothing (pnp: found 0
/// devices), so console=ttyS0 points at a tty that never registers and the disks
/// never appear.
fn addDsdt(b: *almanac.Builder, dsdt: ?[]const u8, comptime is_arm: bool) !u64 {
    if (dsdt) |d| return b.addRaw(d);
    return b.addTable("DSDT", buildDsdt(is_arm), 2);
}

/// Lay down the RSDP over the XSDT and publish it through the shared accessor
/// the UEFI configuration table reads, so the OS finds these tables. Returns the
/// RSDP's address.
fn publish(b: *almanac.Builder, xsdt_phys: u64, fadt_phys: u64) !u64 {
    const rsdp_phys = try b.rsdp(xsdt_phys);
    qemu.setRsdp(@intCast(rsdp_phys));
    console.out.print("[acpi] RSDP @ {x}\n", .{rsdp_phys}) catch {};
    console.out.print("[acpi] XSDT @ {x}, FADT @ {x}\n", .{ xsdt_phys, fadt_phys }) catch {};
    return rsdp_phys;
}

/// Report where the DSDT came from and what it is.
fn reportDsdt(dsdt: ?[]const u8, dsdt_phys: u64) void {
    if (dsdt) |d| {
        // The AML blob is itself an SDT: signature[4], length at offset 4.
        const len = std.mem.readInt(u32, d[4..8], .little);
        console.out.print(
            "[acpi] DSDT @ {x}: '{s}', {d} bytes (provided AML)\n",
            .{ dsdt_phys, d[0..4], len },
        ) catch {};
    } else {
        console.out.print(
            "[acpi] no AML provided. DSDT @ {x} translated from the device tree\n",
            .{dsdt_phys},
        ) catch {};
    }
}

/// The bytes of the table at `phys`. The pool is identity-mapped, so physical
/// and virtual agree, and the header carries the table's length.
fn tableBytes(phys: u64) []const u8 {
    const p: [*]const u8 = @ptrFromInt(@as(usize, @intCast(phys)));
    const len = std.mem.readInt(u32, p[4..8], .little);
    return p[0..len];
}

fn build(dsdt: ?[]const u8) !void {
    var b = newBuilder();
    const dsdt_phys = try addDsdt(&b, dsdt, false);

    // ACPI 6.6 (revision 6, minor version 6). It is the first revision that
    // defines the RISC-V RINTC and PLIC structures the MADT below carries, so
    // an older claimed revision would not describe the table Weir writes.
    const fadt_phys = try b.fadt(.{
        .dsdt_phys = dsdt_phys,
        .hw_reduced = true,
        .minor_version = 6,
    });
    // The provided AML is only the DSDT, so build the tables an OS needs to run
    // in ACPI mode: MADT (harts + PLIC), RHCT (hart ISA/timebase), and SPCR (the
    // console). Without these an OS that sees the RSDP finds no CPUs and hangs.
    const madt_phys = try b.addTable("APIC", madtBody(), madt.revision);
    var rhct_buf: [512]u8 = undefined;
    const rhct = buildRhct(&rhct_buf, soc.timebase_hz, soc.cpu_isa, soc.mmu_type);
    const rhct_phys = try b.addTable("RHCT", rhct, 1);
    const spcr = spcrBody(soc.uart_base);
    const spcr_phys = try b.addTable("SPCR", &spcr, 2);
    const xsdt_phys = try b.xsdt(&.{ fadt_phys, madt_phys, rhct_phys, spcr_phys });
    const rsdp_phys = try publish(&b, xsdt_phys, fadt_phys);

    console.out.print(
        "[acpi] MADT @ {x}, RHCT @ {x}, SPCR @ {x} (16550 @ {x}, PLIC @ {x})\n",
        .{ madt_phys, rhct_phys, spcr_phys, soc.uart_base, soc.plic_base },
    ) catch {};
    console.out.print(
        "[acpi] MADT: {d} hart(s), PLIC {d} sources, GSI base {d}, S-context {?d}\n",
        .{ madt_harts.len, soc.plic_ndev, plic_gsi_base, madt_harts[0].context },
    ) catch {};

    reportDsdt(dsdt, dsdt_phys);
    reportChecksums(rsdp_phys, xsdt_phys, fadt_phys);
}

/// Build the AArch64 table set and report a summary. The AArch64 entry point
/// (src/arm64.zig) calls this when the platform hands over no tables of its own;
/// the RISC-V firmware never reaches it.
pub fn setupArm(dsdt: ?[]const u8) void {
    buildArm(dsdt) catch {
        console.err.writeAll("[acpi] table construction failed (buffer too small)\n") catch {};
    };
}

/// The tables an OS needs on AArch64, where an ACPI OS reads none of the device
/// tree's own nodes: the MADT's GIC records give it the CPUs and the interrupt
/// controller, the GTDT its timer, and the SPCR its console. Without them an OS
/// that sees the RSDP finds no CPUs and hangs.
fn buildArm(dsdt: ?[]const u8) !void {
    var b = newBuilder();
    const dsdt_phys = try addDsdt(&b, dsdt, true);

    // ACPI 6.6, as on RISC-V. The revision has to cover the table revisions
    // below (the GTDT's revision 3 is ACPI 6.1), and the FADT is where an OS
    // reads the revision it is dealing with.
    const fadt_phys = try b.fadt(.{
        .dsdt_phys = dsdt_phys,
        .hw_reduced = true,
        .minor_version = 6,
    });
    var apic_buf: [arm.madtBodyLen(soc.hart_count)]u8 = undefined;
    const apic = arm.madtBody(&apic_buf, soc.harts, soc.gic_dist_base, soc.gic_cpu_base);
    const madt_phys = try b.addTable("APIC", apic, arm.apic_revision);
    var gtdt_buf: [arm.gtdtBodyLen]u8 = undefined;
    const gtdt_phys = try b.addTable("GTDT", arm.gtdtBody(&gtdt_buf, soc.timer_gsivs), arm.gtdt_revision);
    var spcr_buf: [arm.spcrBodyLen]u8 = undefined;
    const spcr = arm.spcrBody(&spcr_buf, soc.uart_base, soc.uart_gsi, if (soc.uart_is_pl011) arm.interface_pl011 else arm.interface_16550);
    const spcr_phys = try b.addTable("SPCR", spcr, arm.spcr_revision);
    const xsdt_phys = try b.xsdt(&.{ fadt_phys, madt_phys, gtdt_phys, spcr_phys });
    const rsdp_phys = try publish(&b, xsdt_phys, fadt_phys);

    console.out.print(
        "[acpi] MADT @ {x}, GTDT @ {x}, SPCR @ {x} ({s} @ {x})\n",
        .{ madt_phys, gtdt_phys, spcr_phys, if (soc.uart_is_pl011) "PL011" else "16550", soc.uart_base },
    ) catch {};
    console.out.print(
        "[acpi] GIC distributor @ {x}, CPU interface @ {x}, {d} core(s)\n",
        .{ soc.gic_dist_base, soc.gic_cpu_base, soc.hart_count },
    ) catch {};

    reportDsdt(dsdt, dsdt_phys);
    reportArmTables(madt_phys, gtdt_phys, spcr_phys);
    reportChecksums(rsdp_phys, xsdt_phys, fadt_phys);
}

/// Read the tables just built back through almanac — the typed accessors an OS's
/// own ACPI layer uses — and report what they say. This is the layout check: a
/// field written at the wrong offset reads back wrong here, on the firmware's
/// own console, rather than silently in the OS.
fn reportArmTables(madt_phys: u64, gtdt_phys: u64, spcr_phys: u64) void {
    const apic = almanac.tables.Madt.fromBytes(tableBytes(madt_phys)) catch {
        console.out.writeAll("[acpi] APIC: unreadable\n") catch {};
        return;
    };
    var cores: usize = 0;
    var gicd: u64 = 0;
    var it = apic.iterator();
    while (it.next() catch null) |entry| switch (entry) {
        .gicd => |d| gicd = d.physical_base_address,
        .gicc => cores += 1,
        else => {},
    };
    const gtdt = almanac.tables.Gtdt.fromBytes(tableBytes(gtdt_phys)) catch {
        console.out.writeAll("[acpi] GTDT: unreadable\n") catch {};
        return;
    };
    const spcr = almanac.tables.Spcr.fromBytes(tableBytes(spcr_phys)) catch {
        console.out.writeAll("[acpi] SPCR: unreadable\n") catch {};
        return;
    };
    console.out.print(
        "[acpi] read back: GICD @ {x}, {d} GICC, EL1 timer GSIV {d}, {s} @ {x}, GSI {d}\n",
        .{
            gicd,
            cores,
            gtdt.nonSecureEl1Gsiv(),
            @tagName(spcr.interfaceType()),
            spcr.baseAddress().address,
            spcr.globalSystemInterrupt(),
        },
    ) catch {};
}

fn reportChecksums(rsdp_phys: u64, xsdt_phys: u64, fadt_phys: u64) void {
    const rsdp_b: [*]const u8 = @ptrFromInt(@as(usize, @intCast(rsdp_phys)));
    const xsdt_b: [*]const u8 = @ptrFromInt(@as(usize, @intCast(xsdt_phys)));
    const fadt_b: [*]const u8 = @ptrFromInt(@as(usize, @intCast(fadt_phys)));
    const ok_rsdp = almanac.checksum.valid(rsdp_b[0..36]);
    const xsdt_len = std.mem.readInt(u32, xsdt_b[4..8], .little);
    const ok_xsdt = almanac.checksum.valid(xsdt_b[0..xsdt_len]);
    const ok_fadt = almanac.checksum.valid(fadt_b[0..276]); // ACPI 6.x FADT
    console.out.print(
        "[acpi] checksums: RSDP={s} XSDT={s} FADT={s}\n",
        .{ okStr(ok_rsdp), okStr(ok_xsdt), okStr(ok_fadt) },
    ) catch {};
}

fn okStr(ok: bool) []const u8 {
    return if (ok) "ok" else "FAIL";
}
