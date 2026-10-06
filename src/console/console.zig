//! Global firmware console over the platform UART.
//!
//! The console binds the UART driver the platform declares, a 16550-style part
//! or an ARM PL011, and exposes conduit `std.Io` streams over it, like EDK II's
//! ConOut, StdErr, and ConIn: `out` for normal status, `err` for failures, and
//! `input` for serial input. The streams reach the one UART today, but a caller
//! picks a stream by intent, so `err` can divert later. Write through
//! `out`/`err` (`out.print`, `err.writeAll`); read through `input`. The writers
//! are unbuffered, so every byte reaches the UART at once and a message survives
//! a later hang. The reader never blocks: it returns the bytes waiting now, or
//! none.

const std = @import("std");
const conduit = @import("conduit");
const platform = @import("../platform.zig");
const soc = @import("soc");

// The console UART device and a conduit std.Io stream for each direction.
// init() fills them before any use, so `undefined` never reaches a read.
// zippy:ignore unsafe_undefined
var dev: Uart = undefined;
// zippy:ignore unsafe_undefined
var ws_out: conduit.device.Serial.Writer = undefined;
// zippy:ignore unsafe_undefined
var ws_err: conduit.device.Serial.Writer = undefined;
// zippy:ignore unsafe_undefined
var ws_in: conduit.device.Serial.Reader = undefined;

/// The UART driver this platform's console needs. The two register maps are not
/// compatible, so the wrong one programs unrelated offsets.
const Uart = if (soc.uart_is_pl011)
    conduit.driver.pl011.Pl011
else
    conduit.driver.ns16550a.Ns16550a;

// Empty buffers: the writers send every write at once with no pending tail, and
// the reader reflects the UART state at the instant it is read.
var out_buf: [0]u8 = .{};
var err_buf: [0]u8 = .{};
var in_buf: [0]u8 = .{};

/// Normal status output. Valid only after `init`.
pub const out: *std.Io.Writer = &ws_out.interface;
/// Failure output. Valid only after `init`.
pub const err: *std.Io.Writer = &ws_err.interface;
/// Serial input. Non-blocking: a read returns the waiting bytes, or none. Valid
/// only after `init`.
pub const input: *std.Io.Reader = &ws_in.interface;

/// True once `init` has bound the UART. A trap handler reports only when this
/// holds: printing through an unbound console would fault inside the reporter.
pub var ready: bool = false;

/// Last-resort output for the first instructions of the firmware and for the
/// handlers that run before `init`: a panic, or a trap on the way to the
/// console. It writes the data register of the UART the platform declares,
/// straight from the tree's address, with no driver and no buffering.
///
/// This is not a substitute for `init`. A 16550-style part needs its divisor
/// programmed before it transmits at all, so on such a platform this is a no-op
/// and the report is lost; a PL011 transmits from reset, which is why the
/// bring-up path can use it. Either way it does not touch the `out`/`err`
/// streams, so nothing here can fault inside an uninitialized writer.
pub fn emergencyWriteAll(bytes: []const u8) void {
    if (!soc.uart_is_pl011) return;
    const fr: *volatile u32 = @ptrFromInt(platform.uartBase() + pl011_fr);
    const dr: *volatile u32 = @ptrFromInt(platform.uartBase() + pl011_dr);
    for (bytes) |byte| {
        while (fr.* & pl011_fr_txff != 0) {}
        dr.* = byte;
    }
}

/// Emergency output of `value` as 16 hex digits.
pub fn emergencyWriteHex(value: u64) void {
    var i: u6 = 16;
    while (i > 0) {
        i -= 1;
        const nibble: u8 = @truncate(value >> (i * 4));
        emergencyWriteAll(&.{if (nibble < 10) '0' + nibble else 'a' + (nibble - 10)});
    }
}

// PL011 register offsets, used only by `emergencyWriteAll`.
const pl011_dr = 0x00;
const pl011_fr = 0x18;
const pl011_fr_txff = 1 << 5;

pub fn init() void {
    if (soc.uart_is_pl011) {
        dev = conduit.driver.pl011.bind(conduit.Mmio.direct(platform.uartBase()));
    } else {
        // River gates TX on a nonzero divisor, where baud = clock / divisor. It
        // also stalls on FCR/MCR writes, so bind with minimal_init. QEMU virt
        // ignores the divisor and accepts the full init, so this path serves
        // both.
        dev = conduit.driver.ns16550a.bind(conduit.Mmio.direct(platform.uartBase()), .{
            .divisor = @intCast(soc.uart_clock / 115200),
            .minimal_init = true,
        });
    }
    ws_out = dev.serial().writer(&out_buf);
    ws_err = dev.serial().writer(&err_buf);
    ws_in = dev.serial().reader(&in_buf);
    ready = true;
}
