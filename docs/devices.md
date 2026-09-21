# Devices

The targets Weir runs on, and their status. QEMU emulates a generic RISC-V
machine and a generic AArch64 machine for development. The others are River SoCs
on a Digilent Arty S7-50. See [testing.md](testing.md) for the setup.

| Target | Status | OS | Storage |
| --- | --- | --- | --- |
| QEMU virt | Tested | A PE bootloader or the Linux EFI stub | virtio-blk |
| QEMU aarch64 virt | Tested | An AArch64 EFI application | none yet |
| Creek V1 | Tested | Boots the Ferrite kernel | SD card, tested |
| Delta V1 | Tested | Boots, no OS yet | SD card, detected |

## QEMU

The `qemu-system-riscv64 -machine virt` target. Its DRAM works at reset, so it
needs no FSBL. It boots a PE bootloader or the Linux EFI stub when you provide
one. Its storage is virtio-blk, and it has no SPI, so the SD-in-SPI path does not
run there. It carries a goldfish RTC, so the wall clock works.

## QEMU aarch64 virt

The `qemu-system-aarch64 -machine virt` target, built with `zig build arm64`.
QEMU resets it into EL2 and the firmware drops to EL1, where UEFI puts the boot
loader. It runs an AArch64 EFI application embedded with `-Dpe-app`, either from
the ESP when the machine has a disk or straight from memory. Its DRAM works at
reset and its console is a PL011, so it needs no FSBL and no console tuning.

It has no disk in the default setup, so it does not yet run an OS. The ACPI
tables QEMU hands it through fw_cfg are the ones it publishes; with
`-machine virt,acpi=off` it builds its own, which is the path a board takes. See
[building.md](building.md).

## Creek V1

Tested on the Arty S7. It boots the Ferrite kernel. The SD card over SPI is
tested.

## Delta V1

Tested on the Arty S7. It boots, but it runs no OS yet. The SD card over SPI is
detected.
