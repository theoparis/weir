# Testing

Weir runs on two very different targets: QEMU and real hardware. They catch
different bugs, so use both. QEMU is fast and proves the firmware logic. Hardware
proves the timing, the analog margins, and the SoC quirks that QEMU does not
model.

## Host tests

```
zig build test
```

These run on the build machine. They build the platform-independent parts against
a host conduit, so they cover what an OS reads off the wire without any hardware:
the MADT, GTDT and SPCR bodies (`src/acpi/`), and the SoC parameters `src/soc.zig`
resolves from the embedded tree at compile time. A tree that stops declaring
something, or a table field that moves, fails here rather than on a board.

Conduit, the driver library, has its own host tests for the driver protocol
logic, such as the SD-SPI identification sequence and the console writer.

## QEMU

```
zig build qemu
```

This boots `weir-firmware.bin` under `qemu-system-riscv64 -machine virt`. QEMU
tests the firmware end to end: the SBI calls, the UEFI services, the ACPI and
SMBIOS tables, and the boot path.

QEMU does not model the River SoC. It provides a generic 16550 UART, a goldfish
RTC, and virtio-blk storage. Build with `-Ddtb` to embed a board's device tree,
but the machine QEMU runs is still `virt`.

## QEMU aarch64

```
zig build arm64
zig build qemu-arm64
```

The second boots `weir-arm64.bin` under `qemu-system-aarch64 -machine virt`. It
covers the AArch64 bring-up (the MMU, the GIC, the architectured timer, PSCI for
the secondary cores) and the same UEFI environment the RISC-V image builds.

QEMU hands that machine its own ACPI tables through fw_cfg, so add `acpi=off` to
see Weir build and publish its own - the path a board takes:

```
qemu-system-aarch64 -machine virt,acpi=off -cpu cortex-a57 -smp 2 -m 2G \
  -nographic -bios zig-out/bin/weir-arm64.bin
```

To run an EFI application, embed it and give it its command line:

```
zig build arm64 -Dpe-app=app.efi -Dcmdline="--some-option"
```

Give the machine a display (`-device ramfb`) and Weir publishes a Graphics Output
Protocol over it, with the framebuffer in firmware RAM; an app that draws into
`Mode->FrameBufferBase` shows up on QEMU's display. Add `-display none -device
ramfb` to keep the serial console as the only output, and `-qmp unix:/tmp/q,server,nowait`
with the monitor's `screendump shot.ppm` if you want to capture what the app drew
rather than watch it.

## Hardware

The reference hardware is a River Creek V1 or Delta V1 SoC on a Digilent Arty
S7-50 FPGA board. An SD card sits in a Digilent Pmod SD on the JA connector,
wired to the SoC's SPI master. The FSBL brings up DDR, then loads and runs the
main firmware. See [devices.md](devices.md) for the tested devices and their
status.

Flash `weir-fsbl.bin` at the boot address and `weir-firmware-packed.bin` at the
`river-firmware` partition. Read the console over the UART.

## What only hardware catches

QEMU is more forgiving than silicon, so it hides a class of bugs. Test these on
hardware before you trust them.

| Class | On QEMU | On hardware |
| --- | --- | --- |
| Misaligned access | Emulated | Traps (mcause 4 or 6) |
| DDR write margin | Every write sticks | A marginal word can drop |
| Flash access width | Any width reads | The controller may need a fixed width |
| UART register quirks | Accepts the full init | River stalls on FCR/MCR writes |
| SPI and SD timing | Not modeled | Real clock and turnaround |

A change that passes QEMU can still fault or hang on the SoC. Two real cases: the
console writer walked off an empty vector as a misaligned load, and the flash
copy path hit the marginal DDR write. Both passed QEMU and showed only on River.
See [debugging.md](debugging.md) for how to chase such a failure on hardware.

## Before you trust a change

- `zig build test` in conduit is green.
- `zig build qemu` boots the firmware.
- A change to the FSBL, the DDR path, the flash copy, the console, or any MMIO
  access gets a boot on the reference hardware.
