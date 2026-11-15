# AXI4-Stream ⇄ Framed 4-Lane Digital Link Bridge — RTL to GDSII

SARCathon 2026 (IIT Bombay), Stage 2. A bidirectional digital bridge in Verilog, taken from RTL through Yosys synthesis and OpenLane 2.3.10 physical design on SKY130 HD at a 20 ns clock (top: `pd_top_bidir`).

Full technical report: [reports/SARCathon_Stage2_Final_Report.pdf](reports/SARCathon_Stage2_Final_Report.pdf)

## My contribution (Priya Kyal)
This was a three-person project and the ASIC flow was a joint effort. My main areas:
- **FPGA prototype:** built `fpga_demo_top` around the bridge and ran it on a Nexys 4 DDR, covering Vivado simulation, implementation, bitstream generation and on-board bring-up. A demo video was recorded. See [`fpga/`](fpga/).
- **Yosys synthesis:** ran the synthesis measurements for the layers and the top, tracked cell, flop and runtime changes across RTL iterations (Layer 3: 31,333 to 9,838 cells, 229 s to about 9 s synthesis; see [`synthesis/synthesis_summary.md`](synthesis/synthesis_summary.md)), and generated the per-module schematics in [`synthesis/yosys_images/`](synthesis/yosys_images/).
- **Team support:** helped with RTL review, verification and the physical-design runs.

```text
TX:  2 × 512-bit AXI4-Stream ─► L2 packet-atomic arbiter ─► L1 ingress slice
        ─► L3 256-byte FLIT packetizer + CRC-32 ─► L4 framer ─► 4 lanes × 596 bit (2-bit Gray symbols)
RX:  4 lanes ─► L4 decoder (inverse Gray, magic + metadata CRC + data CRC)
        ─► exact AXI4-Stream beat reconstruction (TKEEP / TLAST)
```

- **Frame:** 2384 bits on 4 lanes. Per-beat TKEEP, TLAST and valid metadata are protected by a metadata CRC. CRC is IEEE CRC-32 (zlib convention).
- **RX behaviour:** bad frames are dropped. `rx_error_code`: 3 = bad magic, 2 = metadata CRC, 1 = data CRC.
- **Scope:** a synchronous digital-link model. It is **not** a full PCIe 6.0 controller, and has no FEC, SerDes, link training or memory-mapped AXI4 bridge.

## Results (measured)

### Functional verification (Icarus Verilog 12.0)
Run `scripts/run_regression.sh 10`. Log: `results/regression_summary.log` (ends with `REGRESSION_STATUS: ALL_PASS`).

| Suite | Result |
|---|---|
| Directed, layers 1–4 + top | 162 checks, 0 failed |
| Bidirectional loopback (backpressure, one corrupted frame) + 1000 protocol reference cases | PASS, 6 good / 1 bad frame |
| Layer 3 random vs zlib golden: random (N=500), network (N=300), jumbo (N=100), ML (N=100) | all 4 profiles PASS |
| RX scoreboard (600 frames, original and new RX) vs independent Python model | PASS, 0 failures |
| CRC equivalence (23,274 vectors; 1353-frame TX equivalence) | PASS |
| Random top-level, seeds 1–10 (random TKEEP, gaps, backpressure, mid-traffic reset) | 10 / 10 PASS |

### Synthesis (Yosys 0.33 + ABC, `pd_top_bidir`)

| Version | Area (µm²) | Reset flops |
|---|---|---|
| original bidirectional | 488,979 | n/a |
| v6 | 464,364 | 5,353 |
| **v7 (this repo)** | **436,959** | **21** |

### Physical design (OpenLane 2.3.10, 2300 × 2300 µm die, 20 ns)

| Metric | Value |
|---|---|
| Setup WNS (worst corner, max_ss_100C_1v60) | +3.159 ns, 0 violations |
| Hold WNS (same corner) | −0.938 ns, 5636 violations (tt/ff corners ≥ +0.11 ns) |
| DRC (route / Magic / KLayout) | 0 / 0 / 0 |
| LVS | clean |
| Antenna | 34 violating nets after repair |
| Instances / area / utilization | 187,011 / 930,505 µm² / 17.9 % |

**Status:** setup, DRC and LVS are clean. Hold at the SS corner, 34 antenna nets and max slew/cap/fanout violations remain, so this is **not a fully clean sign-off**. Against the original bidirectional run (about −35.5 ns setup WNS, ~330 antenna nets), the v7 changes (flat CRC XOR network, reset-free datapath registers, antenna-aware config) fixed setup and cut antenna nets about 10×. Details: [reports/openlane_v7_results.md](reports/openlane_v7_results.md).

## Repository layout

| Path | Contents |
|---|---|
| `rtl/` | Layers 1–4, CRC blocks, bidirectional top, PD wrappers (`pd_top_bidir.v` is the OpenLane top) |
| `rtl_alt/` | Earlier Layer 3 versions, kept for comparison |
| `tb/` | Directed, randomized, scoreboard and equivalence testbenches (`tb/ref/` = reference RX/TX) |
| `scripts/` | CRC generator, golden models, vector generators, `run_regression.sh` |
| `sim/` | Generated stimulus vectors and waveform dumps |
| `results/` | Simulation logs, regression summary, GTKWave screenshots (`waves/`) |
| `synthesis/` | Yosys / STA flow scripts, summaries, schematics (`yosys_images/`), gate-count video |
| `physical_design/` | OpenLane configs, run log, metrics, SDC, LEF, zipped netlist, chip layout image |
| `reports/` | Final report (PDF), design document, OpenLane v7 results, timing comparison, Stage 1 report (historical TX-only baseline) |
| `fpga/` | Nexys 4 DDR prototype: description, top-level schematic, Vivado screenshots |

The full layout GDS (`pd_top_bidir.gds`, zipped) is attached to the Releases page because of its size.

## Reproduce

```bash
# Simulation (Icarus Verilog 12 + Python 3)
make all                 # layers 1-4, top, bidir, protocol-check
make rxsb crceq
make random PROFILE=network N=300 STALL=0 GAP=0 SEED=11
make toprand SEED=3 NPK=40 TGAP=2 TBP=70
scripts/run_regression.sh 10

# Physical design (OpenLane 2.3.10, Docker)
python3 -m openlane --dockerized --run-tag v7_2300_20ns physical_design/config_bidir.json
```

## FPGA prototype
Implemented and run on a Nexys 4 DDR (Artix-7 XC7A100T) with Vivado 2025.2; see [fpga/README.md](fpga/README.md).

## Known limitations / next steps
- Fix SS-corner hold violations and the remaining antenna nets.
- Reduce max slew/cap/fanout counts.
- Try an 18 ns clock (not attempted).
- The mutation-fault check (three injected RX faults, all caught) was run on v6 and not repeated on v7.

## Team
Team Code Geass: Daksh Beniwal · Priya Kyal · Lakshay Gupta (IIT Ropar)
