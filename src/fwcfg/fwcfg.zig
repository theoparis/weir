//! QEMU fw_cfg over MMIO. Used to pull QEMU's generated ACPI tables
//! (etc/acpi/tables, etc/acpi/rsdp, etc/table-loader), as EDK2/OVMF does, and
//! republish them to the OS, and to configure the ramfb display device.
//!
//! Reads use the byte-stream (non-DMA) path: the ACPI blobs are small, so
//! throughput does not matter. Writes use the DMA channel, which is the only one
//! QEMU still implements — see `write`.

const std = @import("std");

// QEMU virt places the fw-cfg-mmio device here (DTB node fw-cfg@10100000,
// reg = <0x10100000 0x18>, compatible "qemu,fw-cfg-mmio"). The base is set from
// the DTB at discovery. 0 means no fw-cfg device exists on this platform (e.g.
// a real River SoC). Probing a hardcoded address blind faults on a bus with no
// device mapped there, so every entry point guards on base != 0.
var base_v: usize = 0;
const REG_DATA: usize = 0x00; // selected item streams out a byte at a time
const REG_SELECTOR: usize = 0x08; // 16-bit, big-endian
const REG_DMA: usize = 0x10; // 64-bit, big-endian: address of a DMA access descriptor

// The DMA channel, the only write path QEMU has left: `fw_cfg_write()` (the
// data-register write) has been an empty function since QEMU v2.4, so a guest
// cannot write a file by selecting it and pushing bytes out of the data
// register. Instead the guest lays a descriptor in RAM — the control word
// carries the selector in its top half plus the SELECT and WRITE bits, then the
// transfer length, then the payload's guest-physical address — and writes the
// descriptor's address to the DMA register. That store runs the entire transfer
// inside QEMU's MMIO handler.
const DMA_CTL_ERROR: u32 = 0x01;
const DMA_CTL_SELECT: u32 = 0x08;
const DMA_CTL_WRITE: u32 = 0x10;

/// One DMA access descriptor, exactly as the device reads it (FWCfgDmaAccess).
/// All three fields are big-endian; the fields sum to 16 bytes, so this layout
/// carries no padding on either side.
const DmaAccess = extern struct {
    control: u32,
    length: u32,
    address: u64,
};

/// The descriptor handed to the device, filled in by `write`. A fixed buffer
/// rather than a stack local, like the rest of this firmware's device-facing
/// state: the device reads these 16 bytes out of RAM by address, so the honest
/// shape is a buffer that outlives one call.
var dma_access: DmaAccess = undefined; // zippy:ignore unsafe_undefined

const SELECTOR_SIGNATURE: u16 = 0x0000; // reads "QEMU"
const SELECTOR_FILE_DIR: u16 = 0x0019;

/// Set the MMIO base from the platform's DTB discovery. Pass 0 to mark fw-cfg
/// absent (the default), which makes present() report false without any access.
pub fn setBase(base: usize) void {
    base_v = base;
}

fn selectorReg() *volatile u16 {
    return @ptrFromInt(base_v + REG_SELECTOR);
}

fn dataReg() *volatile u8 {
    return @ptrFromInt(base_v + REG_DATA);
}

fn dmaReg() *volatile u64 {
    return @ptrFromInt(base_v + REG_DMA);
}

/// Select an item. This also resets its read offset to zero.
fn select(key: u16) void {
    selectorReg().* = @byteSwap(key); // the selector register is big-endian
}

fn readBytes(buf: []u8) void {
    const d = dataReg();
    for (buf) |*b| b.* = d.*;
}

fn skipBytes(n: usize) void {
    const d = dataReg();
    var i: usize = 0;
    // The volatile read advances the fw_cfg stream. We discard the value.
    while (i < n) : (i += 1) _ = d.*; // zippy:ignore discarded_error
}

fn readBe32() u32 {
    var b: [4]u8 = undefined;
    readBytes(&b);
    return (@as(u32, b[0]) << 24) | (@as(u32, b[1]) << 16) | (@as(u32, b[2]) << 8) | b[3];
}

fn readBe16() u16 {
    var b: [2]u8 = undefined;
    readBytes(&b);
    return (@as(u16, b[0]) << 8) | b[1];
}

pub const File = struct { selector: u16, size: u32 };

/// Is a fw_cfg device present? Confirms by reading the "QEMU" signature, which
/// also validates our selector-register endianness.
pub fn present() bool {
    if (base_v == 0) return false; // no fw-cfg on this platform: do not poke MMIO
    select(SELECTOR_SIGNATURE);
    var sig: [4]u8 = undefined;
    readBytes(&sig);
    return std.mem.eql(u8, &sig, "QEMU");
}

/// Look a file up in the fw_cfg directory by name.
pub fn find(name: []const u8) ?File {
    select(SELECTOR_FILE_DIR);
    const count = readBe32();
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const size = readBe32();
        const sel = readBe16();
        skipBytes(2); // skip the 2-byte reserved field
        var namebuf: [56]u8 = undefined;
        readBytes(&namebuf);
        const n = std.mem.indexOfScalar(u8, &namebuf, 0) orelse namebuf.len;
        if (std.mem.eql(u8, namebuf[0..n], name)) return .{ .selector = sel, .size = size };
    }
    return null;
}

/// Read a file's full contents into `buf` (must be at least `file.size`).
pub fn read(file: File, buf: []u8) void {
    select(file.selector);
    readBytes(buf[0..file.size]);
}

/// Write `data` to `file`. One transfer holds the whole file: the device fails a
/// write whose length disagrees with the item's own length, so there is no
/// chunked form of this that works.
///
/// This is how QEMU's ramfb device is told about a framebuffer (see
/// uefi/gop.zig): `etc/ramfb` is a write-only file, and the guest hands the
/// device the address it should scan out — the direction of the exchange is the
/// opposite of every other fw_cfg file, which the guest reads.
///
/// The payload address in the descriptor is guest-physical, not the virtual one
/// the caller's pointer names: QEMU walks the system address space with it. Weir
/// identity-maps RAM on both architectures, so the two are the same number here,
/// and the pointer goes in unchanged.
///
/// Returns false when the device reports an error — a descriptor it could not
/// read, a length that disagrees with the item size, or an item it did not
/// register as writable. The transfer runs synchronously inside the store to the
/// DMA register, so the control word is already written back when that store
/// retires and one read reports the outcome.
pub fn write(file: File, data: []const u8) bool {
    // Volatile stores: the device reads this out of memory while the store to
    // the DMA register below is in flight, so every field has to be in RAM
    // before that store, not merely live in registers.
    const desc: *volatile DmaAccess = &dma_access;
    desc.* = .{
        .control = @byteSwap(DMA_CTL_SELECT | DMA_CTL_WRITE | (@as(u32, file.selector) << 16)),
        .length = @byteSwap(@as(u32, @intCast(data.len))),
        .address = @byteSwap(@as(u64, @intFromPtr(data.ptr))),
    };
    dmaReg().* = @byteSwap(@as(u64, @intFromPtr(&dma_access)));
    // The control word is the device's, not ours: read it back volatile.
    const ctl: *volatile u32 = @ptrCast(&dma_access.control);
    return (@byteSwap(ctl.*) & DMA_CTL_ERROR) == 0;
}
