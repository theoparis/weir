# Building

Weir builds with Zig 0.16 and needs no other build tools. The `qemu` target also
needs qemu-system-riscv64. The repository is a Nix flake, so `nix develop` gives
you a shell with both.

```
nix develop          # optional: a shell with Zig and QEMU
zig build            # build the firmware and the FSBL
zig build qemu       # boot under qemu-system-riscv64 -machine virt
zig build arm64      # build the AArch64 image
zig build qemu-arm64 # boot it under qemu-system-aarch64 -machine virt
```

`zig build` installs to `zig-out/bin`:

- `weir-firmware.elf` - the linked firmware, for debugging.
- `weir-firmware.bin` - the flat image for QEMU `-bios`.
- `weir-firmware-packed.bin` - the flat image with the header the FSBL reads.
- `weir-fsbl.bin` - the first-stage boot loader.
- `weir-arm64.elf` / `weir-arm64.bin` - the AArch64 image, from `zig build arm64`.

To run these on QEMU or write them to a board, see [flashing.md](flashing.md).

## AArch64

`zig build arm64` builds a separate image, `src/arm64.zig`, for AArch64. It links
and discovers against an AArch64 tree (`-Ddtb`, default `tools/arm64-virt.dtb`)
and shares everything above the bring-up with the RISC-V firmware. QEMU resets it
into EL2 and the entry drops to EL1, where the UEFI specification puts the boot
loader.

By default QEMU hands the machine its own ACPI tables through fw_cfg, and Weir
publishes those. To make Weir build and publish its own — the path a real board
takes — take the machine's tables away:

```
qemu-system-aarch64 -machine virt,acpi=off -cpu cortex-a57 -smp 4 -m 4G \
  -nographic -bios zig-out/bin/weir-arm64.bin
```

## Build options

Pass a board's device tree with `-Ddtb` to build for real hardware:

```
zig build -Ddtb=board.dtb
```

| Option | Meaning |
| --- | --- |
| `-Ddtb=PATH` | Device tree. Weir reads its SoC addresses from it at compile time. |
| `-Daml=PATH` | ACPI DSDT AML blob to embed. |
| `-Dpayload=PATH` | An S-mode ELF payload to embed and jump to. |
| `-Dpe-app=PATH` | A PE32+ EFI application to embed and load. |
| `-Dcmdline=ARG` | The initial image's command line, published as its UEFI load options. |
| `-Ddisk-boot` | Read the boot PE off a disk, not an embedded blob. |
| `-Dboot-manager` | Boot through the ESP boot manager (GPT, FAT, BootOrder). |
| `-Dinitrd=PATH` | An initramfs to serve the kernel through LoadFile2. |
