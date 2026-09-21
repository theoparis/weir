# Porting

Weir reads its hardware addresses from a device tree at build time. It holds no
hardcoded addresses, so a port to a new board is mostly a matter of supplying a
device tree.

## The device tree drives the build

`src/soc.zig` reads the embedded device tree at compile time. It matches each
node's `compatible` string to a device class and lowers the node's `reg` into an
address. Build for a board by passing its tree:

```
zig build -Ddtb=board.dtb
```

With no `-Ddtb`, Weir falls back to the QEMU `virt` addresses.
[device-tree.md](device-tree.md) is the full reference for the nodes and
properties Weir reads.

The `conduit` library does the matching and the driver work. `soc.zig` bakes one
matcher per class Weir needs:

| Class | Purpose | Example `compatible` |
| --- | --- | --- |
| `uart` | console | `ns16550a`, `snps,dw-apb-uart`, `arm,pl011` |
| `timer` | CLINT / machine timer, or the architectured timer | `riscv,clint0`, `arm,armv8-timer` |
| `intc` | external interrupt controller | `riscv,plic0`, `arm,cortex-a15-gic` |
| `memory` | main DRAM | `memory` |
| `flash` | XIP boot flash | `jedec,spi-nor` |
| `sdram` | DDR controller (for the FSBL) | `harbor,sdram-controller` |
| `tpm` | measured boot | `tcg,tpm-tis-mmio` |
| `rtc` | wall clock | `google,goldfish-rtc` |
| `block` | SD/MMC host | `harbor,sdhci` |
| `spi` | SPI master (SD in SPI mode) | `harbor,spi` |

A device is optional. When the tree has no node for a class, Weir uses a default
or turns the feature off. The console UART, the CLINT, and the memory node are
the minimum a board needs.

## AArch64

An AArch64 board is a port of the same kind. It supplies a device tree, and the
same `src/soc.zig` reads it: the console, the GIC, the architectured timer and
the RAM windows all come from the tree, and no part of the platform layer has an
address of its own. What differs is the arch layer behind `src/arch.zig`
(`src/arch/arm64`): the bring-up drops from EL2 to EL1 and enables an MMU with
its own tables, PSCI starts the secondary cores, and the GIC and the system
counter replace the PLIC and the CLINT.

Two facts a tree has to get right, because the firmware passes them on rather
than inventing them:

- **The timer's interrupts.** The timer node lists the four architectured timers
  in order (secure EL1, non-secure EL1, virtual EL1, non-secure EL2). The
  firmware runs on the non-secure EL1 timer, and it is that entry — not a
  constant — that its own interrupt setup uses and that the ACPI GTDT publishes.
  A tree that lists them out of order gives the OS a timer the firmware is not
  running on.
- **The interrupt controller's two windows.** A GICv2 node's `reg` holds the
  distributor first and the CPU interface second. The firmware binds the CPU
  interface, and the ACPI MADT describes both.

The build takes the tree with `-Ddtb`, and `tools/arm64-virt.dtb` is QEMU's
aarch64 `virt` machine dumped for the default. The ACPI tables an AArch64 board
publishes differ from the RISC-V set; see [acpi.md](acpi.md).

## The linker script follows the tree

The host tool `tools/fdt2ld.zig` reads the same tree and generates the linker
script. The main firmware links at the DRAM `memory` base. The FSBL links for
XIP from the flash window and keeps its writable state in DRAM (or on-chip SRAM
when the tree has an `mmio-sram` node).

## DRAM training

When the SoC calibrates its DDR in hardware, load `weir-firmware.bin` directly
and skip the FSBL.

When the SoC leaves the DDR training to the CPU, such as some River SoCs, use the
FSBL. It runs from flash or SRAM, trains and brings up the DDR controller, copies
the main image into DRAM, and jumps to it. Flash `weir-fsbl.bin` at the boot
address and `weir-firmware-packed.bin` at the `river-firmware` partition. The
packed image carries the header the FSBL reads. See [fsbl.md](fsbl.md).

## Adding a peripheral driver

Weir gets its drivers from `conduit`. To support a new device:

1. Add the driver to conduit, or reuse one it already has.
2. Give the board's device tree a node with a `compatible` string the conduit
   driver matches.
3. If the device is a new class Weir must discover, add a matcher to the
   `matchers` table in `src/soc.zig`.

## Console notes

Weir binds conduit's `ns16550a` driver for the console. River's minimal UART
does not acknowledge writes to the FIFO or modem-control registers, so Weir
binds it with `minimal_init`, which programs only the line-control and baud
registers. QEMU accepts the full init, so the one path serves both.
