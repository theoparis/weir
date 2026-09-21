# Device tree

Weir reads its hardware from a device tree at build time. `src/soc.zig` matches
each node by its `compatible` string and reads its address. `tools/fdt2ld.zig`
reads the same tree to lay out the linker script. This is the reference for the
nodes and properties Weir reads.

Pass the tree with `-Ddtb`. With none, Weir uses the QEMU `virt` addresses. See
[porting.md](porting.md) for the porting flow.

## Peripherals

Weir matches one node per device class. It reads the MMIO base from `reg`, and a
clock rate from `clock-frequency` where it needs one.

| Class | `compatible` | Weir reads |
| --- | --- | --- |
| UART | `ns16550a`, `snps,dw-apb-uart`, `arm,pl011` | console base, clock, interrupt (the SPCR's GSI) |
| Timer | `riscv,clint0`, `sifive,clint0`, `arm,armv8-timer` | CLINT base and tick rate, or the architectured timer's four interrupts |
| Interrupt controller | `riscv,plic0`, `arm,cortex-a15-gic`, `arm,gic-400`, `arm,gic-v2` | PLIC windows and contexts, or the GIC's distributor and CPU interface |
| Memory | (a node with `device_type = "memory"`) | DRAM base, size |
| Flash | `jedec,spi-nor` | XIP flash base |
| DDR controller | `harbor,sdram-controller` | training window (FSBL) |
| TPM | `tcg,tpm-tis-mmio` | TIS base |
| RTC | `google,goldfish-rtc` | wall clock |
| SD/MMC host | `harbor,sdhci`, `harbor,sdio` | block base, clock |
| SPI master | `harbor,spi`, `midstall,harbor-spi` | SPI base for an SD card |

The console UART, the CLINT, and the memory node are the minimum a board needs.
An absent class turns its feature off or falls back to a default.

## AArch64 bindings

The same table with AArch64 nodes, and two things a board has to get right
because the firmware passes them on rather than inventing them:

- **The timer node lists four interrupts**, in architectured order: secure EL1,
  non-secure EL1, virtual EL1, non-secure EL2. Weir runs on the non-secure EL1
  timer, so that entry — not a constant — is both the interrupt its own timer
  setup enables and the one the ACPI GTDT publishes. Out of order, the OS is
  handed a timer the firmware is not using.
- **A GIC node's `reg` holds two windows**, distributor first and CPU interface
  second. Weir binds the CPU interface; the ACPI MADT describes both.

The console is either a 16550-compatible part or a PL011 (`arm,pl011`), which is
a different register map: the ACPI SPCR names which one it is, and the OS must
not program a PL011 as a 16550.

## Clocks

The CLINT `mtime` runs at the timer's `clock-frequency`. The software wall clock
uses this rate to count seconds when the board has no RTC. Weir defaults to 10
MHz, the QEMU rate, when the tree omits it. The UART baud divisor comes from the
UART node's `clock-frequency` the same way.

## Flash partitions

The flash node holds a `fixed-partitions` subnode with `partition@NNN` leaves.
Each leaf has a `reg = <offset size>` and a `label`. Weir reads two by label:

- `river-fsbl` - the FSBL runs XIP from here. This offset clears the FPGA
  bitstream slot on an FPGA board.
- `river-firmware` - the main image lives here. Its offset and size set where the
  FSBL looks and how large the image may be.

With no partition map, Weir uses the legacy defaults (the FSBL at the flash base,
the main image at offset `0x100000`).

## On-chip SRAM

An `mmio-sram` node gives the FSBL a scratch window for its stack and writable
state. Without it, the FSBL uses the DRAM window instead.

## DDR training

A DDR controller that needs runtime training carries a `training` child node. It
describes the knob register window and an ordered list of `knob@N` nodes. Each
knob has a scope (`global`, `per-lane`, or `per-bit`), a feedback mode
(`pattern` or `map`), and a tap range. The FSBL reads this at build time and
sweeps each knob at boot. See [fsbl.md](fsbl.md).
