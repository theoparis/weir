# Status

What Weir does today, and what is planned. This is a snapshot, not a promise.

## Working

- **Boot.** Runs on QEMU and on River Creek V1, where it boots the Ferrite
  kernel. See [devices.md](devices.md).
- **AArch64.** A second image (`zig build arm64`, `src/arm64.zig`) boots on
  QEMU's aarch64 `virt` machine and on ARM boards: it brings up an MMU, the GIC
  and the architectured timer, starts the secondary cores through PSCI, and runs
  an AArch64 EFI application in the same UEFI environment the RISC-V image
  builds. It reads the same platform layer, so a board joins by supplying a
  device tree. See [porting.md](porting.md).
- **SBI.** Base, TIME, IPI, RFENCE, HSM, DBCN, and SRST, plus the legacy console
  and shutdown. Console input and the real machine CSR IDs. See [sbi.md](sbi.md).
- **UEFI.** The boot and runtime services a PE bootloader or the Linux EFI stub
  needs: memory, protocols, ExitBootServices, the variable services, and
  GetTime/SetTime. Block, filesystem, LoadFile2, and RISC-V boot protocols. See
  [uefi.md](uefi.md).
- **Platform tables.** ACPI (hardware-reduced), SMBIOS, and the device tree,
  handed to the OS through the configuration table. On AArch64 the table set is
  the MADT's GIC records, the GTDT, and the SPCR, unless the platform hands its
  own over.
- **Display.** A Graphics Output Protocol over QEMU's ramfb, so a boot loader
  that paints a framebuffer has one to paint on.
- **Measured boot.** TPM 2.0 over TIS, with a PCR chain and an event log. See
  [measured-boot.md](measured-boot.md).
- **First-stage boot loader.** DDR training and image load, for SoCs that need
  it. See [fsbl.md](fsbl.md).
- **Storage.** virtio-blk, an SD/MMC host, and an SD card over SPI, with a GPT
  and FAT boot manager.

## Planned

- **Secure boot.** Authenticate each image against a key before it runs. This is
  the next security step after measured boot.
- **More OS support.** Delta V1 boots the firmware but runs no OS yet.
- **A framebuffer on real hardware.** The Graphics Output Protocol is backed by
  QEMU's ramfb, which is an emulated display. Conduit carries a virtio-gpu
  driver, so a board with a virtio display can get the same protocol over it.
- **Netboot.** A network stack, to boot over PXE or HTTP.

## In Progress

- **Smaller UEFI and SBI gaps.** An RNG protocol, and the SBI PMU extension.
