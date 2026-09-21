# ACPI

Weir gives the OS ACPI tables so it can enumerate the platform without a device
tree. The OS finds the tables through the ACPI RSDP in the UEFI configuration
table. The code lives in `src/acpi/`, and it builds the tables with `almanac`,
conduit's ACPI table builder.

Weir uses the hardware-reduced ACPI model, which fits a RISC-V platform.

## Two sources

Weir builds ACPI tables one of two ways, depending on the platform.

**On QEMU**, Weir reads the tables QEMU already prepared. It runs QEMU's fw_cfg
table-loader (`src/acpi/qemu.zig`), which lays QEMU's DSDT, FADT, MADT, and RHCT
into memory and links them. These match the emulated machine exactly.

**On real hardware**, Weir builds the tables itself (`src/acpi/acpi.zig`). It
lays a minimum set into a static buffer and stamps every checksum:

- RSDP, which points at the XSDT.
- XSDT, which lists the FADT, the MADT, the RHCT and the SPCR.
- FADT, hardware-reduced, whose `X_DSDT` points at the DSDT. It claims ACPI 6.6,
  the first revision that defines the RISC-V MADT structures below.
- MADT, one RINTC per hart plus the PLIC structure.
- RHCT, the hart timebase, ISA string and MMU type.
- SPCR, the 16550 console.

## Interrupts

On the ACPI path the OS gets the PLIC's GSI base, source count, register window
and context map from the MADT, not from the DSDT. So the MADT must agree with
the hardware. Weir reads the values from the device tree (`src/soc.zig`): the
PLIC node's `reg` and `riscv,ndev`, and its `interrupts-extended`, which lists
the PLIC contexts in context order.

Each hart gets exactly one RINTC. Its external interrupt controller ID names the
PLIC context that drives that hart's **supervisor** external interrupt, because
the OS runs in S-mode. Weir keeps the machine context of the same hart for
itself. A second RINTC for one hart would make the OS see a CPU that does not
exist.

The PLIC's GSI base in the MADT must equal the `_GSB` of the PLIC device in the
DSDT. The OS matches the two to attach the MADT record to the DSDT device. A
DSDT whose PLIC device has no `_GSB` breaks that link, and then the OS never
probes the PLIC.

The CLINT has no ACPI interrupt binding on purpose. Weir owns it in M-mode and
gives the OS its timer through SBI.

The DSDT comes from one of two places. A board may supply a raw AML blob with
`-Daml`, and Weir references it in place. With no AML, Weir translates the
device tree into one: every matched node becomes a device with its `reg` and
`interrupts` as `_CRS`, under a native HID where one exists (the interrupt
controller, the console UART) and under `PRP0001` with the node's `compatible`
in `_DSD` where none does, which is the device-tree bridge an OS already knows
how to bind.

## AArch64

An AArch64 board builds its table set from the same two sources, with different
tables, because an ACPI OS reads none of a device tree's own nodes there:

- MADT, whose GIC structures carry the CPUs and the interrupt controller. There
  is one GICD record for the distributor and one GICC record per core. The core
  entries take their MPIDR from the tree, which is what an OS matches a CPU
  against.
- GTDT, the architectured timer: the counter control base (none, the counter is
  programmed through the system registers) and the timer interrupt list. The
  GSIVs come from the timer node's `interrupts`, which names the four timers in
  architectured order (secure EL1, non-secure EL1, virtual EL1, non-secure EL2).
  The secure and virtual-EL2 entries stay zero: this firmware runs no EL3 for
  the OS to reach, and gives it no EL2.
- SPCR, the console. An AArch64 SPCR describes the console's GSI and its
  register map family — a PL011 and a 16550 are not the same device — where the
  RISC-V one describes a polled 16550.

The DSDT differs too. A GIC has no ACPI HID an OS could bind: the OS takes it
from the MADT, so Weir leaves the interrupt controller out of the DSDT entirely
rather than give it a RISC-V HID that would mislabel it. The console UART keeps
a device, under the HID its driver matches: `ARMH0011` for a PL011, `PNP0501`
for a 16550.

## TPM

When the platform has a TPM and the ACPI table set has no TPM2 table, Weir
synthesizes one and points it at the TCG event log. So the OS finds the log and
can extend the measured-boot chain Weir started.

## Identity

Weir stamps the tables with the OEM ID `MIDSTL` and the OEM table ID `WEIR`.
