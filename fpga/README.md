# FPGA prototype: Nexys 4 DDR (Artix-7 XC7A100T)

The bridge (`top_4layer_bidir`) was implemented and run on hardware as a self-checking demo
(`fpga_demo_top`). Tool: Vivado 2025.2. Target: `xc7a100tcsg324-1`.

## What the demo contains
(see `fpga_demo_top_schematic.pdf`)
- **Clocking and reset:** 100 MHz board clock into an MMCM; `CPU_RESETN` through a reset synchronizer.
- **Traffic sources:** two pseudo-random AXI4-Stream packet generators feeding the bridge's two ingress ports.
- **Loopback:** TX lanes routed back into the RX lanes, with bit-flip injection to exercise the CRC and error paths.
- **Checker:** compares received beats against expected data; counts packets per source, partial packets and error classes (CRC, data, ordering, protocol).
- **Status output:** UART report (RUN / PASS / FAIL) plus LEDs and switches.

## Flow
Vivado behavioural simulation, then synthesis, implementation, bitstream generation, and programming over JTAG in Hardware Manager.

## Files
| File | Content |
|---|---|
| `fpga_demo_top_schematic.pdf` | Elaborated top-level schematic of `fpga_demo_top` |
| `Vivado.jpeg` | Hardware Manager: bitstream written, XC7A100T programmed |
| `Vivado_1.jpeg` | Implemented design: placement on the XC7A100T |
