//! EFI_MP_SERVICES_PROTOCOL: what an application uses to count the processors,
//! ask about them, and run a procedure on another one.
//!
//! The application processors this drives are the secondary cores the platform
//! brought up and parked in `apLoop` — the firmware's holding loop. Nothing here
//! powers a core on or off per call: the cores are already running, waiting on an
//! assignment, so starting work is a store and a wake rather than a PSCI
//! round-trip, and a procedure that runs twice does not pay for two power-ups.
//!
//! Work is assigned one core at a time and the caller waits for the result. A
//! WaitEvent is honored by signalling it once the procedure has run: this
//! firmware has no interrupt path to an application processor's completion, so
//! the signal comes from the core that made the request, after it has observed
//! the work finish.
//!
//! SwitchBSP and EnableDisableAP answer EFI_UNSUPPORTED. Neither is a gap in this
//! implementation: PSCI cannot change which core is the boot processor, and an
//! application processor parked in the holding loop cannot be stopped and
//! restarted without a power-off path the firmware does not use.

const std = @import("std");
const uefi = std.os.uefi;
const builtin = @import("builtin");
const handledb = @import("handledb.zig");
const events = @import("events.zig");
const arch = @import("../arch.zig");
const console = @import("../console/console.zig");

const Status = uefi.Status;
const ok = @intFromEnum(Status.success);

// EFI_MP_SERVICES_PROTOCOL_GUID 3fdda605-a76e-4f46-ad29-12f4531b3d08.
pub const MP_SERVICES_GUID = uefi.Guid{
    .time_low = 0x3fdda605,
    .time_mid = 0xa76e,
    .time_high_and_version = 0x4f46,
    .clock_seq_high_and_reserved = 0xad,
    .clock_seq_low = 0x29,
    .node = .{ 0x12, 0xf4, 0x53, 0x1b, 0x3d, 0x08 },
};

/// The procedure an application asks a processor to run. It takes the argument
/// the caller passed and returns nothing.
pub const Procedure = *const fn (?*anyopaque) callconv(.c) void;

/// How many application processors the platform parked. Set by `install`, and
/// 0 on a platform that brought up no secondaries, in which case the protocol is
/// not installed at all.
var ap_count: usize = 0;

/// An assignment in flight, or the state of the core that took it.
///
/// `assigned` is set by the requesting core and observed by the application
/// processor; `finished` travels back the other way. The procedure and argument
/// are written before the state changes, so the release/acquire pair on `state`
/// is what publishes them.
var ap_state: [max_aps]u32 = [_]u32{idle} ** max_aps;
var ap_procedure: [max_aps]?Procedure = [_]?Procedure{null} ** max_aps;
var ap_argument: [max_aps]?*anyopaque = [_]?*anyopaque{null} ** max_aps;

/// The application processors the firmware can be asked to start. The tree
/// declares the cores; this is an upper bound on the ones with a holding loop.
pub const max_aps = 7;

const idle: u32 = 0;
const assigned: u32 = 1;
const finished: u32 = 2;

// EFI_PROCESSOR_INFORMATION.StatusFlag.
const processor_as_bsp: u32 = 1;
const processor_enabled: u32 = 1 << 1;

/// EFI_PROCESSOR_INFORMATION: what GetProcessorInfo reports about one processor.
pub const ProcessorInformation = extern struct {
    processor_id: u64,
    status_flag: u32,
    location: u32,
};

/// EFI_MP_SERVICES_PROTOCOL. Every function here takes this interface as its
/// first argument, the way every EFI protocol does: the application passes the
/// pointer it located, and omitting the parameter shifts every other argument.
const Protocol = extern struct {
    get_number_of_processors: *const anyopaque,
    get_processor_info: *const anyopaque,
    startup_this_ap: *const anyopaque,
    startup_all_aps: *const anyopaque,
    switch_bsp: *const anyopaque,
    enable_disable_ap: *const anyopaque,
    who_am_i: *const anyopaque,
};

// install() fills this before any EFI caller reads it.
var proto: Protocol = undefined; // zippy:ignore unsafe_undefined

/// Publish the protocol, over `count` application processors. The platform calls
/// this once both the secondary cores and the UEFI environment exist.
pub fn install(count: usize) void {
    ap_count = @min(count, max_aps);
    proto = .{
        .get_number_of_processors = @ptrFromInt(@intFromPtr(&getNumberOfProcessors)),
        .get_processor_info = @ptrFromInt(@intFromPtr(&getProcessorInfo)),
        .startup_this_ap = @ptrFromInt(@intFromPtr(&startupThisAp)),
        .startup_all_aps = @ptrFromInt(@intFromPtr(&startupAllAps)),
        .switch_bsp = @ptrFromInt(@intFromPtr(&switchBsp)),
        .enable_disable_ap = @ptrFromInt(@intFromPtr(&enableDisableAp)),
        .who_am_i = @ptrFromInt(@intFromPtr(&whoAmI)),
    };
    // The handle table has room during environment setup, so this cannot fail.
    _ = handledb.install(null, &MP_SERVICES_GUID, @ptrCast(&proto)); // zippy:ignore discarded_error
    console.out.print("[mp] {d} application processor(s) published\n", .{ap_count}) catch {};
}

// --- The application processor side -----------------------------------------

/// The holding loop a parked application processor runs. It waits for an
/// assignment, runs the procedure, and reports back, forever.
///
/// This replaces the idle park: a core sitting in `wfe` cannot be given work
/// without a power cycle, and this one can.
pub fn apLoop(index: u32) noreturn {
    while (true) {
        // `wfe` may wake for its own reasons, so the state is re-read in a loop
        // rather than slept on once.
        while (@atomicLoad(u32, &ap_state[index], .acquire) != assigned) {
            arch.cpu.idle();
        }
        const procedure = ap_procedure[index].?;
        const argument = ap_argument[index];
        procedure(argument);
        @atomicStore(u32, &ap_state[index], finished, .release);
    }
}

/// Wake every parked core. A core that is already awake takes the state change
/// when it next looks; the `sev` is what breaks the others out of `wfe`.
fn wakeAll() void {
    asm volatile ("sev");
}

// --- The requesting processor side ------------------------------------------

fn getNumberOfProcessors(_: *Protocol, number: ?*usize, enabled: ?*usize) callconv(.c) usize {
    const total = ap_count + 1; // the application processors and the boot core
    if (number) |n| n.* = total;
    if (enabled) |e| e.* = total;
    return ok;
}

fn getProcessorInfo(_: *Protocol, number: usize, info: ?*ProcessorInformation) callconv(.c) usize {
    if (info == null) return @intFromEnum(Status.invalid_parameter);
    if (number > ap_count) return @intFromEnum(Status.invalid_parameter);
    // The boot core is 0; the rest are the application processors in the order
    // the platform brought them up.
    const is_bsp = number == 0;
    info.?.* = .{
        .processor_id = if (is_bsp) bspId() else 0,
        .status_flag = processor_enabled | (if (is_bsp) processor_as_bsp else 0),
        .location = @intCast(number),
    };
    return ok;
}

/// The boot core's MPIDR on AArch64, which is what a caller can compare against
/// MPIDR_EL1. On a platform without one, the processor number stands in.
fn bspId() u64 {
    if (builtin.cpu.arch != .aarch64) return 0;
    return asm volatile ("mrs %[v], mpidr_el1"
        : [v] "=r" (-> u64),
    );
}

/// Which processor this call is running on. 0 is the boot core.
fn whoAmI(_: *Protocol, number: ?*usize) callconv(.c) usize {
    if (number == null) return @intFromEnum(Status.invalid_parameter);
    if (builtin.cpu.arch != .aarch64) {
        number.?.* = 0;
        return ok;
    }
    const mpidr = bspId();
    // The application processor's stack identifies it in the holding loop, but
    // from inside a procedure the only identity is the core it is running on, and
    // the affinity value is what the tree and PSCI both key on.
    var i: usize = 0;
    while (i < ap_count) : (i += 1) {
        if (archApAffinity(i) == mpidr) {
            number.?.* = i + 1;
            return ok;
        }
    }
    number.?.* = 0;
    return ok;
}

/// The affinity value of application processor `index`, as the platform
/// registered it. Set by `setApAffinity`, or 0 when the platform only reported a
/// count.
var ap_affinity: [max_aps]u64 = [_]u64{0} ** max_aps;

/// Record an application processor's affinity value, so WhoAmI can name the core
/// a procedure is running on. The platform calls this for each core it parked.
pub fn setApAffinity(index: usize, affinity: u64) void {
    if (index < max_aps) ap_affinity[index] = affinity;
}

fn archApAffinity(index: usize) u64 {
    if (index < ap_affinity.len) return ap_affinity[index];
    return 0;
}

fn startupThisAp(
    _: *Protocol,
    number: usize,
    wait_event: ?*anyopaque,
    timeout_us: usize,
    procedure: ?Procedure,
    argument: ?*anyopaque,
    out_finished: ?*bool,
) callconv(.c) usize {
    if (procedure == null) return @intFromEnum(Status.invalid_parameter);
    // Processor 0 is the requesting core: the boot processor cannot start itself.
    if (number == 0 or number > ap_count) return @intFromEnum(Status.invalid_parameter);
    const ap = number - 1;
    if (@atomicLoad(u32, &ap_state[ap], .acquire) == assigned)
        return @intFromEnum(Status.invalid_parameter);

    assign(ap, procedure.?, argument);
    const result = awaitCompletion(ap, timeout_us);
    if (result != ok) return result;
    if (out_finished) |f| f.* = true;
    signalIfEvent(wait_event);
    return ok;
}

/// StartupAllAPs takes its arguments in a different order from StartupThisAP:
/// the procedure and the single-thread flag come first, then the wait event and
/// the timeout. Getting that wrong shifts every argument, which is exactly how
/// this read before the order was corrected here.
fn startupAllAps(
    _: *Protocol,
    procedure: ?Procedure,
    single_thread: bool,
    wait_event: ?*anyopaque,
    timeout_us: usize,
    argument: ?*anyopaque,
    out_finished: ?*bool,
) callconv(.c) usize {
    if (procedure == null) return @intFromEnum(Status.invalid_parameter);
    if (ap_count == 0) return @intFromEnum(Status.not_found);

    // A single-threaded request runs on one application processor, which is what
    // the flag means: the caller wants the procedure run once, not once per core.
    const want = if (single_thread) 1 else ap_count;
    for (0..want) |ap| {
        if (@atomicLoad(u32, &ap_state[ap], .acquire) == assigned)
            return @intFromEnum(Status.invalid_parameter);
    }
    for (0..want) |ap| assign(ap, procedure.?, argument);

    const deadline = deadlineFor(timeout_us);
    for (0..want) |ap| {
        const result = awaitCompletionWithDeadline(ap, deadline);
        if (result != ok) return result;
    }
    if (out_finished) |f| f.* = true;
    signalIfEvent(wait_event);
    return ok;
}

/// Hand the work to one application processor and wake it.
fn assign(ap: usize, procedure: Procedure, argument: ?*anyopaque) void {
    ap_procedure[ap] = procedure;
    ap_argument[ap] = argument;
    @atomicStore(u32, &ap_state[ap], assigned, .release);
    wakeAll();
}

fn awaitCompletion(ap: usize, timeout_us: usize) usize {
    return awaitCompletionWithDeadline(ap, deadlineFor(timeout_us));
}

/// Wait for the application processor to report. A timeout of 0 means wait as
/// long as it takes, which is what the protocol says it means.
fn awaitCompletionWithDeadline(ap: usize, deadline: ?u64) usize {
    while (@atomicLoad(u32, &ap_state[ap], .acquire) != finished) {
        if (deadline) |d| {
            if (arch.time.now() >= d) return @intFromEnum(Status.timeout);
        }
    }
    return ok;
}

fn deadlineFor(timeout_us: usize) ?u64 {
    if (timeout_us == 0) return null;
    // UEFI timeouts are microseconds; the counter is in ticks.
    return arch.time.now() + events.ticks(@as(u64, timeout_us) * 10);
}

/// Signal the caller's event, if it gave one. This is how the asynchronous form
/// of the call learns the work is done.
fn signalIfEvent(wait_event: ?*anyopaque) void {
    const event = events.of(wait_event) orelse return;
    events.signal(event);
}

fn switchBsp( // zippy:ignore too_many_params UEFI SwitchBSP ABI is fixed
    _: *Protocol,
    number: usize,
    enable_old_bsp: bool,
) callconv(.c) usize {
    _ = number;
    _ = enable_old_bsp;
    // Which core is the boot processor is the platform's decision (PSCI's, on
    // AArch64), and it is fixed for the life of the boot.
    return @intFromEnum(Status.unsupported);
}

fn enableDisableAp( // zippy:ignore too_many_params UEFI EnableDisableAP ABI is fixed
    _: *Protocol,
    number: usize,
    enable: bool,
    health: ?*u32,
) callconv(.c) usize {
    _ = number;
    _ = enable;
    _ = health;
    // An application processor here is parked in the firmware's holding loop and
    // stays there: there is no power-off path in use that could stop it, so there
    // is nothing to disable.
    return @intFromEnum(Status.unsupported);
}
