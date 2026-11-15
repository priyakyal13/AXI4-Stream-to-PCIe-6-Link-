> **Revision/scope note (2026-10-23):** This report documents the original TX-only implementation and its measurements. The later bidirectional digital-link extension is described separately in `reports/bidirectional_extension.md`; that new RTL still requires HDL simulation and physical-design validation. Do not interpret the TX-only GDSII or metrics in this report as results for `pd_top_bidir`.

# SARCathon 2026 Stage 2 — Technical Design Report

**Project:** AXI4/AXI4-Stream to PCIe 6 digital bridge prototype  
**Implementation flow:** Verilog/SystemVerilog RTL, Icarus Verilog simulation, Yosys synthesis, OpenLane 2 / Sky130 physical design  
**Report status:** Draft based on the repository logs and a user-supplied 20 ns metrics dump. Antenna-repair and 18 ns results are pending and must be added from their actual run folders.

## 1. Executive summary

The design is a scoped four-layer digital transmit datapath for the SARCathon 2026 challenge. Two 512-bit AXI4-Stream sources feed packet-atomic arbitration and an ingress register slice. Layer 3 combines four 512-bit beats into a 256-byte FLIT, masks bytes with `TKEEP`, zero-pads partial FLITs, and computes CRC-32. Layer 4 maps the FLIT plus CRC into four digital lane outputs using 2-bit symbol mapping and Gray coding.

The source ZIP contains logs showing **162/162 directed checks passed** and a passing Layer 3 random run (14,736 checks; zero failures). User-provided OpenLane 2 results for the 20 ns run report setup WNS of +2.457 ns, hold WNS of +0.104 ns, zero Magic/KLayout DRC errors and a clean LVS comparison. However, the same baseline still reports **160 antenna-violating nets and 169 violating pins**, as well as max-slew, max-capacitance and max-fanout violations. Therefore the physical design is not yet fully signoff-clean.

## 2. Challenge objective and implementation scope

The challenge requests RTL optimization, exhaustive functional verification, network and ML workload testing, synthesis analysis, an OpenROAD/OpenLane implementation, and final GDSII. The current prototype covers a substantial TX path and has a baseline physical implementation, but it is not a complete PCIe 6.0 controller or a full PCIe 6.0 PHY.

In particular, it does not implement the full PCIe transaction/data-link protocol, a complete RX direction, analog SerDes behavior, or full PCIe 6.0 FEC. The implemented FLIT contains 256 bytes of data plus a 4-byte CRC, which is a project-specific format rather than the complete PCIe 6.0 FLIT field layout. This distinction should remain explicit in the submission.

## 3. Architecture

1. **Layer 1 — AXI4-Stream ingress:** one-beat register slice with `TVALID`/`TREADY` backpressure and propagation of `TDATA`, `TKEEP`, and `TLAST`.
2. **Layer 2 — arbitration:** two-master packet-atomic arbitration so beats from different packets are not interleaved.
3. **Layer 3 — packetizer/CRC:** four 512-bit beats form 2,048 bits (256 bytes); a 32-bit CRC is appended. The Stage 2 rewrite uses incremental CRC logic instead of a single FLIT-wide combinational CRC cone. Partial packets are padded with zero bytes and use the zero-skip CRC logic in the current RTL.
4. **Layer 4 — digital lane mapping:** the 2,080-bit FLIT-plus-CRC word contains 1,040 2-bit symbols, mapped across four 520-bit lane outputs. This is a wide parallel digital boundary, not a physical serialized PCIe lane interface.

## 4. Functional verification evidence

The saved logs report:

| Test suite | Checks passed | Checks failed | Result |
|---|---:|---:|---|
| Layer 1 | 32 | 0 | PASS |
| Layer 2 | 33 | 0 | PASS |
| Layer 3 | 29 | 0 | PASS |
| Layer 4 | 39 | 0 | PASS |
| Integration | 29 | 0 | PASS |
| **Total directed/integration** | **162** | **0** | **PASS** |

The Layer 2 log reports zero atomicity invariant violations. The included random Layer 3 log records 19,648 input beats and 4,912 FLITs, with 14,736 checks passed and zero failures. The log does not identify the named workload profile or fully preserve the exact invocation, so it must not be presented as a specific network/jumbo/ML result without new, tagged runs.

This evidence supports passing directed tests and a particular random Layer 3 run, but **does not by itself establish exhaustive verification**. SVA/formal evidence, coverage percentages, error injection, random reset-mid-packet tests, and independently logged per-profile workloads should be added if completed; otherwise they remain limitations.

## 5. Synthesis optimization

The project notes record these user-run Yosys measurements:

| Metric | Stage 1 Layer 3 | Stage 2 Layer 3 checkpoint | Stage 2 Layer 4 checkpoint |
|---|---:|---:|---:|
| Cell count | 31,333 | 9,838 | 3,125 |
| Flip-flops | 4,134 | 2,087 | 2,081 |
| XOR/XNOR count | 18,419 | ~5,030 | — |
| Synthesis time | 229 s | ~9 s | ~0.5 s |

These figures show a substantial reported reduction for Layer 3 and that Layer 4 can synthesize within the prior time budget. They are historical recorded checkpoint values, not a fresh synthesis of the exact final v5 source in this environment. A final submission should rerun Yosys on the exact commit and archive the complete console output/version.

## 6. OpenLane 2 baseline at 20 ns

The following values were supplied from the baseline run metrics by the team; the raw OpenLane run directory was not included in the ZIP, so they have not been re-parsed independently here.

| Metric | User-reported result |
|---|---:|
| Clock period / target frequency | 20 ns / 50 MHz |
| Setup WNS / TNS | +2.457049744 ns / 0 |
| Hold WNS / TNS | +0.103522305 ns / 0 |
| Setup / hold violation count | 0 / 0 |
| Magic DRC errors | 0 |
| KLayout DRC errors | 0 |
| LVS | Clean; net/device/pin differences = 0 |
| Antenna violations | 160 nets / 169 pins |
| Antenna cells inserted/reported | 2,021 |
| Max-slew / max-cap / max-fanout violation count | 718 / 50 / 291 |
| Disconnected pins / power-grid violations | 0 / 0 |
| Die area | 2,890,000 µm² (1.7 mm × 1.7 mm) |
| Core area | 2,833,980 µm² |
| Standard-cell instance area | 445,507 µm² (0.4455 mm²) |
| Reported standard-cell utilization | 15.7202% |
| Instance count | 74,828 |
| Total-power raw metric | 0.0248476733 (unit not independently confirmed) |

The implementation is timing-clean against its 20 ns constraint in the supplied summary and reports clean DRC/LVS, but the remaining antenna and electrical-rule violations must be discussed and investigated. A low utilization is not automatically an area win: the wide top-level I/O boundary (reported 3,244 I/Os) and fixed die floorplan dominate this setup. The present wide digital lane bus is a known architectural limitation and potential future area/timing optimization point, but changing it would require RTL regression and a fresh physical-design flow.

## 7. Antenna-repair experiment and clock sweep

The current experiment is configured in `physical_design/config_ant.json`. It holds the clock at 20 ns and adds:

- `DIODE_ON_PORTS = "in"`
- `GRT_ANTENNA_ITERS = 10`
- `GRT_ANTENNA_MARGIN = 25`

These settings request extra input-port diode protection and more aggressive global-route antenna repair. They do not prove the design is fixed. The next required evidence is the final `route__antenna_violation__count`, the antenna violation report, DRC/LVS, setup/hold and area/power metrics from the tagged `v5_20ns_ant` run. If violations remain, inspect the violating net/pin report to identify whether the causes are input ports, output ports or internal routes before changing strategy.

After recording Run A, run a separate 18 ns configuration with the same antenna settings and a unique tag. The 18 ns point is a timing experiment, not a confirmed pass. Do not state an 18 ns result until the actual final timing report is available.

## 8. Throughput interpretation

A 512-bit accepted input beat carries 64 bytes. At one beat per cycle and a 20 ns period, the raw input interface ceiling is:

`512 bits × 50 MHz = 25.6 Gbit/s`

This is a calculated logical datapath ceiling before `TKEEP` inefficiency, packet bubbles, or backpressure. It is **not** a PCIe 6.0 physical link-rate claim. The output uses four extremely wide 520-bit lane buses in parallel; this design does not serialize those buses into a standard PCIe PHY interface. Throughput results for network, jumbo-packet and ML profiles must be separately measured on the final RTL with the exact command, seed, `STALL`, `GAP`, cycle counts, payload bytes and FLIT counts preserved.

## 9. Known limitations and next work

1. Complete the 20 ns antenna-repair experiment and capture its reports.
2. Run the 18 ns antenna-configured point and summarize the timing/area/power trade-off.
3. Rerun all directed tests, multiple random seeds, and separate `network`, `jumbo`, and `ml` profiles on the exact final RTL.
4. Re-run Yosys on the current v5 Layer 3 and Layer 4 modules; preserve version, stats, and elapsed time.
5. Add or document SVA/formal assertions and functional coverage. Do not label the current tests exhaustive without this evidence.
6. Consider buffering/packet packing, output serialization, RX/CRC-checking with error injection, and a more spec-faithful FLIT layout as future scope, only if time permits.
7. Archive the GDSII, DEF/LEF, final `metrics.json`, DRC/LVS reports, configuration and run logs from the final successful tag. Make the final ZIP reproducible and keep large layout artifacts separate if size limits require it.

## 10. Conclusion

The saved RTL regression is passing and the team has a useful 20 ns physical-design baseline with positive setup/hold slack and reported zero DRC/LVS errors. The design is not yet fully clean because the baseline contains antenna and max slew/cap/fanout violations. The next defensible milestone is to measure the antenna-repair configuration, use the actual metrics to decide the next change, and then carry out the 18 ns timing experiment. Claims about the final GDSII and signoff status should only be updated from those actual run artifacts.
