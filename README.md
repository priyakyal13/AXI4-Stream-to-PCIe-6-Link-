# AXI4 (Master & Slave) to PCIe 6 Link — Stage 1 Submission
### SARCathon 2026 — Semiconductor Challenge

## What this is

A 4-layer RTL implementation of the challenge's reference architecture:
two AXI4-Stream masters arbitrated onto one channel, buffered, packed
into fixed 256-byte FLITs with CRC-32, and split across 4 lanes with
Gray/PAM4 symbol coding — the digital boundary of an AXI4-to-PCIe bridge.

See `reports/design_document.md` for the full technical write-up
(architecture, per-layer operation, verification methodology, and known
limitations/scope decisions).

## Project structure

```
project_root/
├── rtl/                          RTL source files (one per architecture layer)
│   ├── layer1_axis_stream_ingress.v
│   ├── layer2_axis_arbiter.v
│   ├── layer3_flit_packetizer.v
│   ├── layer4_flit_to_phy_lanes.v
│   └── top_4layer_true_split.v   top-level integration
├── tb/                            Testbench and verification files (one per layer + integration)
├── sim/                           Build directory (compiled binaries + live waveform dumps
│                                   land here when you run `make` — see sim/NOTE.md)
├── results/                       Pass/fail logs + waveform (.vcd) files, already generated
│                                   from the current, final RTL (see below)
├── synthesis/
│   └── yosys_lint_summary.md      Synthesis/lint sanity check (Yosys) — optional, not a
│                                   Stage 2 substitute
├── physical_design/                Empty — GDSII/physical design is Stage 2, not Stage 1
│                                   (see physical_design/NOTE.md)
├── reports/
│   └── design_document.md         Full technical design document
├── Makefile
└── README.md                      This file
```

`results/` **is shipped** with this zip, populated by running `make all`
against the exact RTL/testbench files in this submission immediately
before packaging — so what's in there reflects the current code, not a
stale snapshot from earlier in development. You don't have to take that
on faith, though: running `make all` yourself regenerates everything
from scratch and will reproduce the same pass counts.

## How to reproduce the results

Requires `iverilog` and `vvp` (Icarus Verilog) on `PATH`; `gtkwave`
optional, for viewing waveforms.

```bash
make all        # builds and runs all 5 test suites from a clean state
make layer1     # or run any single layer's test individually
make layer2
make layer3
make layer4
make top        # full 4-layer integration test
make wave       # opens the integration waveform in GTKWave
make clean      # removes build/sim artifacts
```

Each target writes its console output to `results/<name>_result.log` and
its waveform to `results/dump_<module>.vcd`.

## Architecture-to-file mapping

| Spec Architecture Layer | Representative Function | RTL File |
|---|---|---|
| AXI4 / AXI4-Stream Interface | Transaction/data ingress and egress | `rtl/layer1_axis_stream_ingress.v` |
| Interconnect Layer | Routing, crossbar operation and arbitration | `rtl/layer2_axis_arbiter.v` |
| Link Layer | Packetization, framing, CRC/error-handling | `rtl/layer3_flit_packetizer.v` |
| PCIe Protocol-to-PHY Layer | Protocol adaptation, lane-oriented data handling | `rtl/layer4_flit_to_phy_lanes.v` |

## Verification summary

| Suite | Tests | Result |
|---|---|---|
| Layer 1 | 32 | All passed |
| Layer 2 | 33 (incl. atomicity monitor + source-attribution scoreboard) | All passed, 0 atomicity violations |
| Layer 3 | 29 (incl. TKEEP correctness) | All passed |
| Layer 4 | 39 | All passed |
| Full integration | 29 (incl. full-pipeline backpressure) | All passed |
| **Total** | **162** | **162/162 passed** |

Full breakdown, methodology, and the synthesis/lint sanity check (Yosys)
results are in `reports/design_document.md`.

## Known scope decisions (Stage 1)

- **FEC** not implemented — CRC-32 (IEEE 802.3) only.
- **Interconnect** scoped to 2 masters, not a general N-master crossbar.
- **Analog PHY / SerDes** out of scope — Layer 4 stops at the digital
  Gray-coded symbol codes a PAM4 SerDes would consume.
- **Synthesis / GDSII** is a Stage 2 deliverable; this submission covers
  RTL design and functional verification only, per the Stage 1 scope.

Full rationale for each is in `reports/design_document.md`, Section 7.
