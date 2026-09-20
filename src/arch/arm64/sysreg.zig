//! AArch64 system-register access. The register name is comptime, so the
//! assembler encodes it directly. This is the counterpart of
//! src/arch/riscv/csr.zig, which does the same for the CSRs.

pub inline fn read(comptime name: []const u8) u64 {
    return asm volatile ("mrs %[v], " ++ name
        : [v] "=r" (-> u64),
    );
}

pub inline fn write(comptime name: []const u8, value: u64) void {
    asm volatile ("msr " ++ name ++ ", %[v]"
        :
        : [v] "r" (value),
        : .{ .memory = true });
}

pub inline fn set(comptime name: []const u8, mask: u64) void {
    write(name, read(name) | mask);
}

pub inline fn clear(comptime name: []const u8, mask: u64) void {
    write(name, read(name) & ~mask);
}
