//! The boot-services event pool.
//!
//! A UEFI application creates events, arms timers on them, and waits for one to
//! become ready. The pool is small and fixed: firmware runs a handful of events,
//! and an allocator here would be one more thing to get right at a point where
//! nothing can be diagnosed.
//!
//! Readiness is polled, never interrupt-driven. WaitForEvent spins on the pool
//! until some event is ready, which is what the boot-services contract allows and
//! keeps both the timer and the console out of the interrupt path. The counter
//! the timers read is the arch layer's (`arch.time`), so a timer means the same
//! interval on a board whose counter runs at a different rate.
//!
//! This lives apart from the service shims in uefi.zig because more than one
//! service needs it: MP Services signals the caller's event when an application
//! processor finishes its procedure.

const arch = @import("../arch.zig");

/// The EFI_EVENT_TIMER type bit.
pub const timer_type: u32 = 0x8000_0000;

pub const NotifyFn = *const fn (*anyopaque, ?*anyopaque) callconv(.c) void;

/// A readiness test an event may carry instead of a timer. The console's key
/// event is ready when a keystroke is waiting, which only the console can
/// answer, so the test is a function rather than a flag.
pub const ReadyFn = *const fn () bool;

pub const Event = struct {
    used: bool = false,
    is_timer: bool = false,
    /// Set by SignalEvent, cleared when a wait or a check consumes it.
    signaled: bool = false,
    notify_fn: ?NotifyFn = null,
    notify_ctx: ?*anyopaque = null,
    ready_fn: ?ReadyFn = null,
    timer_armed: bool = false,
    periodic: bool = false,
    /// Counter ticks between periodic firings.
    period: u64 = 0,
    /// Counter value the timer fires at.
    deadline: u64 = 0,
};

const max_events = 16;
var pool: [max_events]Event = undefined;

/// Empty the pool. Called once, while the system table is being built.
pub fn init() void {
    for (&pool) |*e| e.used = false;
}

/// Take an event from the pool, or null when they are all in use.
pub fn create(etype: u32, notify_fn: ?NotifyFn, notify_ctx: ?*anyopaque) ?*Event {
    for (&pool) |*e| {
        if (e.used) continue;
        e.* = .{
            .used = true,
            .is_timer = (etype & timer_type) != 0,
            .notify_fn = notify_fn,
            .notify_ctx = notify_ctx,
        };
        return e;
    }
    return null;
}

/// Return an event to the pool.
pub fn close(e: *Event) void {
    e.used = false;
}

/// Validate an EFI_EVENT before dereferencing it: a bogus handle must not deref
/// wild. The pointer has to land on a live slot of the pool.
pub fn of(handle: ?*anyopaque) ?*Event {
    const e: *Event = @ptrCast(@alignCast(handle orelse return null));
    const base = @intFromPtr(&pool[0]);
    const p = @intFromPtr(e);
    if (p < base or p >= base + @sizeOf(Event) * max_events) return null;
    if ((p - base) % @sizeOf(Event) != 0) return null;
    return if (e.used) e else null;
}

/// Is this event ready, i.e. would a wait return it now? A periodic timer
/// advances to its next firing; a one-shot timer disarms as it fires.
pub fn ready(e: *Event) bool {
    if (e.signaled) return true;
    if (e.ready_fn) |f| return f();
    if (e.is_timer and e.timer_armed and arch.time.now() >= e.deadline) {
        if (e.periodic) e.deadline += e.period else e.timer_armed = false;
        return true;
    }
    return false;
}

/// Consume an event's readiness, which is what a wait or a check does with it.
pub fn consume(e: *Event) void {
    e.signaled = false;
}

/// Mark an event ready and run its notification function.
pub fn signal(e: *Event) void {
    e.signaled = true;
    if (e.notify_fn) |f| f(@ptrCast(e), e.notify_ctx);
}

/// Arm, re-arm, or disarm a timer event. `trigger_time` is in 100 ns units, the
/// unit the UEFI timer services use. False means the mode is not one of the
/// three the protocol defines.
pub fn setTimer(e: *Event, mode: u32, trigger_time: u64) bool {
    switch (mode) {
        0 => { // cancel
            e.timer_armed = false;
            e.periodic = false;
        },
        1 => { // periodic
            e.periodic = true;
            e.period = ticks(trigger_time);
            e.timer_armed = true;
            e.deadline = arch.time.now() + e.period;
        },
        2 => { // relative
            e.periodic = false;
            e.timer_armed = true;
            e.deadline = arch.time.now() + ticks(trigger_time);
        },
        else => return false,
    }
    return true;
}

/// 100 ns units to counter ticks. The counter's rate is the arch layer's to
/// report — the board's timebase on RISC-V, the architected frequency on
/// AArch64 — and using one for the other would scale every timer by the ratio.
pub fn ticks(hundred_ns: u64) u64 {
    return hundred_ns * arch.time.frequency() / 10_000_000;
}
