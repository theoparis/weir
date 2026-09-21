//! EFI_GRAPHICS_OUTPUT_PROTOCOL over QEMU's ramfb device.
//!
//! Every other protocol this firmware publishes describes hardware the platform
//! already has. This one is the other way round: the guest owns the pixels. The
//! machine has no device-tree framebuffer node and no board register to read a
//! scan-out address from, so the guest allocates the framebuffer and tells the
//! device where it is through fw_cfg (QEMU's `ramfb`), and the device scans that
//! memory out. That is why the address below is a firmware allocation and not a
//! hardware fact out of soc.zig: nothing in the tree knows it.
//!
//! A machine with no fw_cfg, or one started without `-device ramfb`, gets no GOP
//! at all. That is deliberate: an app that locates a GOP stops looking for a
//! framebuffer, so publishing one that scans out nothing would be worse than
//! publishing none, and the boot continues either way.

const std = @import("std");
const uefi = std.os.uefi;
const fwcfg = @import("../fwcfg/fwcfg.zig");
const handledb = @import("handledb.zig");
const console = @import("../console/console.zig");
const platform = @import("../platform.zig");

const Status = uefi.Status;
const ok = @intFromEnum(Status.success);
const GraphicsOutput = uefi.protocol.GraphicsOutput;

/// The fw_cfg file QEMU's ramfb device registers for writing. Only present when
/// the machine was started with `-device ramfb`, which is also the only case
/// where QEMU gives the machine a display to scan out to.
const RAMFB_FILE = "etc/ramfb";

// The single mode this firmware offers. One mode is the whole story for a
// boot-time framebuffer: the app either draws at the panel's native geometry or
// sets its own timings later, and a second mode would only be a second thing to
// keep consistent with the device.
const WIDTH: u32 = 1280;
const HEIGHT: u32 = 800;
const BPP: u32 = 4;
/// Pixels per scan line, which the GOP reports: this mode has no padding, so a
/// line is exactly as wide as the visible image.
const STRIDE_PIXELS: u32 = WIDTH;
/// Bytes per line, which is what ramfb calls the stride.
const STRIDE: u32 = STRIDE_PIXELS * BPP;
const FRAMEBUFFER_SIZE: usize = @as(usize, STRIDE) * HEIGHT;

/// DRM's fourcc for XRGB8888: the four characters are the four bytes of a pixel,
/// most significant first, so the byte at each address is blue, green, red, and
/// an ignored fourth — B, G, R, X from the lowest address on a little-endian
/// machine. The value below reads 'X' | 'R' << 8 | '2' << 16 | '4' << 24 because
/// the device takes it big-endian, as it does the whole configuration.
const FOURCC_XRGB8888: u32 = 'X' | ('R' << 8) | ('2' << 16) | ('4' << 24);

/// The pixel format the one mode advertises: the one that describes what this
/// framebuffer actually holds.
///
/// XRGB8888's byte order is blue, green, red from the lowest address, and EFI's
/// pixel-format enum names its channels in that same direction — from the least
/// significant byte up. (EDK2's FrameBufferBltLib is the check: its masks for
/// PixelRedGreenBlueReserved8BitPerColor are red 0x000000ff and blue 0x00ff0000,
/// and for the BlueGreenRed form those two are exchanged.) So XRGB8888 is the
/// BlueGreenRed enum, and an app that builds its channel masks from the enum
/// paints red where red goes. The RedGreenBlue form differs from it in exactly
/// that swap, so advertising it here would have every app that trusts the enum
/// draw with red and blue exchanged — QEMU scans these bytes out as they lie.
/// EDK2's QemuRamfbDxe pairs this enum with this fourcc for the same reason.
///
/// What the app writes is a claim this mode has no way to verify: the pixels are
/// its own memory, and the device scans out whatever is there. Getting the
/// advertisement right is what keeps the two in agreement.
const PIXEL_FORMAT: GraphicsOutput.PixelFormat = .blue_green_red_reserved_8_bit_per_color;

/// The size of the ramfb configuration the device expects, in bytes.
const RAMFB_CFG_LEN = 28;

/// The scan-out buffer.
///
/// A fixed page-aligned buffer in .bss, not a bump-allocated region: the device
/// is handed this address once and scans out of it for the rest of the boot, so
/// it must not be reused by a later allocation, and the page alignment keeps
/// 4 MiB of pixel memory from sitting inside a page anything else is handed.
var framebuffer: [FRAMEBUFFER_SIZE]u8 align(4096) = undefined; // zippy:ignore unsafe_undefined

/// The configuration as it goes to the device. Fixed, like the framebuffer: the
/// device reads it out of RAM by address.
var ramfb_cfg: [RAMFB_CFG_LEN]u8 = undefined; // zippy:ignore unsafe_undefined

/// The fw_cfg file to write on SetMode. Set once, by install(), which is also
/// what proves the file exists.
var ramfb_file: fwcfg.File = undefined; // zippy:ignore unsafe_undefined

// Install() fills these before any EFI caller reads them. The mode, its info,
// and the protocol are separate objects because the protocol points at the mode
// and the mode points at the info, and an app reads all three.
var mode_info: GraphicsOutput.Mode.Info = undefined; // zippy:ignore unsafe_undefined
var mode: GraphicsOutput.Mode = undefined; // zippy:ignore unsafe_undefined
var proto: GraphicsOutput = undefined; // zippy:ignore unsafe_undefined

/// Hand the device the framebuffer and the geometry to scan out of it.
///
/// The configuration is QEMU's ABI (RAMFBCfg in hw/display/ramfb.c): the
/// framebuffer's physical address, the pixel format, then width, height, and
/// stride, every field big-endian. It is built as bytes rather than as a Zig
/// struct because an `extern struct` with a u64 field would round the 28-byte
/// layout up to 32, and the device rejects a write whose length is not exactly
/// the file's own size.
fn configure() bool {
    const buf = ramfb_cfg[0..];
    std.mem.writeInt(u64, buf[0..8], @intFromPtr(&framebuffer), .big);
    std.mem.writeInt(u32, buf[8..12], FOURCC_XRGB8888, .big);
    std.mem.writeInt(u32, buf[12..16], 0, .big); // flags: no options to ask for
    std.mem.writeInt(u32, buf[16..20], WIDTH, .big);
    std.mem.writeInt(u32, buf[20..24], HEIGHT, .big);
    std.mem.writeInt(u32, buf[24..28], STRIDE, .big);
    return fwcfg.write(ramfb_file, buf);
}

fn queryMode(
    self: *const GraphicsOutput,
    mode_number: u32,
    size_of_info: *usize,
    info: **GraphicsOutput.Mode.Info,
) callconv(.c) usize {
    _ = self;
    if (mode_number != 0) return @intFromEnum(Status.invalid_parameter);
    size_of_info.* = @sizeOf(GraphicsOutput.Mode.Info);
    info.* = &mode_info;
    return ok;
}

fn setMode(self: *GraphicsOutput, mode_number: u32) callconv(.c) usize {
    _ = self;
    if (mode_number != 0) return @intFromEnum(Status.unsupported);
    // Republish the configuration, which is the same geometry: the device keeps
    // scanning out the same memory either way, so this is where a mode change
    // would re-point it if there were a second mode to change to.
    if (!configure()) return @intFromEnum(Status.device_error);
    return ok;
}

/// Blt answers unsupported. This firmware hands the app a framebuffer it can
/// draw into directly, and every EFI app that wants a GOP for anything other
/// than the address in Mode->FrameBufferBase draws with its own code; emulating
/// blits here would be a pixel path nothing on this platform exercises.
fn blt( // zippy:ignore too_many_params UEFI Blt ABI is fixed
    self: *GraphicsOutput,
    buffer: ?[*]GraphicsOutput.BltPixel,
    operation: GraphicsOutput.BltOperation,
    source_x: usize,
    source_y: usize,
    destination_x: usize,
    destination_y: usize,
    width: usize,
    height: usize,
    delta: usize,
) callconv(.c) usize {
    _ = self;
    _ = buffer;
    _ = operation;
    _ = source_x;
    _ = source_y;
    _ = destination_x;
    _ = destination_y;
    _ = width;
    _ = height;
    _ = delta;
    return @intFromEnum(Status.unsupported);
}

/// Program the ramfb device and publish the protocol over it.
///
/// Does nothing when the machine has no fw_cfg (a board with no such device) or
/// QEMU was started without `-device ramfb`, which is the only way the file
/// below is missing. Neither is an error: a machine with no display to scan out
/// to is a machine whose app has no framebuffer to find, and the boot goes on.
pub fn install() void {
    // fw_cfg is discovered from the comptime tree (platform.zig), and 0 marks it
    // absent. Setting the base here rather than relying on the ACPI loader
    // having run first keeps this path self-contained: the GOP does not depend
    // on whether the machine handed over ACPI tables.
    fwcfg.setBase(platform.fwcfgBase());
    if (!fwcfg.present()) return;
    ramfb_file = fwcfg.find(RAMFB_FILE) orelse return; // no ramfb device on this machine

    if (!configure()) {
        console.out.writeAll("[gop] ramfb rejected the framebuffer configuration\n") catch {};
        return;
    }

    mode_info = .{
        .version = 0,
        .horizontal_resolution = WIDTH,
        .vertical_resolution = HEIGHT,
        .pixel_format = PIXEL_FORMAT,
        .pixel_information = .{ .red_mask = 0, .green_mask = 0, .blue_mask = 0, .reserved_mask = 0 },
        .pixels_per_scan_line = STRIDE_PIXELS,
    };
    mode = .{
        .max_mode = 1,
        .mode = 0,
        .info = &mode_info,
        .size_of_info = @sizeOf(GraphicsOutput.Mode.Info),
        .frame_buffer_base = @intFromPtr(&framebuffer),
        .frame_buffer_size = FRAMEBUFFER_SIZE,
    };
    proto = .{
        // Installed through @ptrFromInt the way every protocol in this firmware
        // is (the services all return Status-sized integers, so the field types
        // std declares do not match the functions' own), and each function's
        // parameter list is the one std.os.uefi declares for the ABI.
        ._query_mode = @ptrFromInt(@intFromPtr(&queryMode)),
        ._set_mode = @ptrFromInt(@intFromPtr(&setMode)),
        ._blt = @ptrFromInt(@intFromPtr(&blt)),
        .mode = &mode,
    };

    // The handle DB has spare capacity during environment setup, so this cannot
    // fail; the handle is what LocateProtocol / HandleProtocol scan, so
    // installing here is what makes the protocol findable.
    _ = handledb.install(null, &GraphicsOutput.guid, @ptrCast(&proto)); // zippy:ignore discarded_error
    console.out.print(
        "[gop] ramfb {d}x{d} XRGB8888, framebuffer @ {x} ({d} KiB)\n",
        .{ WIDTH, HEIGHT, @intFromPtr(&framebuffer), FRAMEBUFFER_SIZE / 1024 },
    ) catch {};
}
