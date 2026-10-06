# Building

Weir builds with Zig 0.16. The QEMU targets need qemu-system-riscv64 and
qemu-system-aarch64 respectively. The repository is a Nix flake, so `nix develop`
provides Zig and QEMU.

```
zig build qemu       # qemu-system-riscv64 -machine virt
zig build qemu-arm64 # qemu-system-aarch64 -machine virt
```

`zig build` installs to `zig-out/bin`:

- `weir-firmware.elf` - the linked firmware, for debugging.
- `weir-firmware.bin` - the flat image for QEMU `-bios`.
- `weir-firmware-packed.bin` - the flat image with the header the FSBL reads.
- `weir-fsbl.bin` - the first-stage boot loader.

To run these on QEMU or write them to a board, see [flashing.md](flashing.md).

## Build options

Pass a board's device tree with `-Ddtb` to build for real hardware:

```
zig build -Ddtb=board.dtb
```

Without `-Ddtb`, the ARM64 targets ask QEMU to generate the aarch64 `virt`
device tree at build time. No separate DTB file is needed for `zig build arm64`
or `zig build qemu-arm64`.

| Option | Meaning |
| --- | --- |
| `-Ddtb=PATH` | Device tree. Weir reads its SoC addresses from it at compile time. |
| `-Daml=PATH` | ACPI DSDT AML blob to embed. |
| `-Dpayload=PATH` | An S-mode ELF payload to embed and jump to. |
| `-Dpe-app=PATH` | A PE32+ EFI application to embed and load. |
| `-Ddisk-boot` | Read the boot PE off a disk, not an embedded blob. |
| `-Dboot-manager` | Boot through the ESP boot manager (GPT, FAT, BootOrder). |
| `-Dinitrd=PATH` | An initramfs to serve the kernel through LoadFile2. |
