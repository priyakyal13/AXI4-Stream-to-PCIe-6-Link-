# Timing / area comparison (MEASURED with synthesis/flow/ - NOT an OpenLane sign-off)

Flow: Yosys 0.33 + ABC (sky130_fd_sc_hd tt) -> OpenROAD 2022 floorplan / global placement / repair_design -> OpenSTA tt/ss/ff,
clock 20 ns, IO delay 20 %, placement-estimated parasitics. No CTS, no routing, no hold fixing, no DRC/LVS.
Calibration (earlier session): this flow was ~2.8 ns optimistic vs OpenLane on TX-only v5. Expect real post-route slack a few ns lower.

| Design | die (um) | setup WNS tt | ss | ff | synth cell area (um2) | reset-flop count |
|---|---|---|---|---|---|---|
| original bidir (earlier session) | 2600 | -26.9 | -66.5 | -10.0 | 488,979 | - |
| v6b (as received; re-measured this session) | 2600 | +7.11 | +1.51 (rst_n recovery) | +9.95 | 464,364 | 5,353 |
| **v7** (datapath resets removed) | 2600 | +9.28 | +3.92 (data path); rst_n recovery +14.2 | +10.60 | 436,959 | 21 |
| **v7** | 2300 | +9.89 | +5.17 | +10.62 | 436,959 (same netlist) | 21 |
| v7 | 2100 | FAILED: place_pins could not place 6514 pins (6132 slots) | | | | |

v6b numbers reproduce the previous session exactly (+7.11 / +1.51 / +9.95).

## What changed v6 -> v7 and why
* The rst_n recovery path (31-repeater chain across the die, 5,353 reset loads) is gone as a limiter: only 21 flops are reset now
  (state/valid/handshake/error flops); recovery slack +1.51 -> +14.2 ns (ss). A registered reset tree/synchronizer was therefore
  NOT added (it would change reset-release timing for no measured gain).
* Synthesized area -5.9 % (dfrtp -> dfxtp).
* Remaining worst ss path (+3.9 ns at 2600, +5.2 at 2300) is a high-fan-out control net feeding datapath enables, not the CRC loop.
  The L3 CRC path was NOT further restructured (not shown to be limiting) - Task 5 is not done.

## Die area
2100 um is infeasible with this pin count (6514 I/O vs 6132 slots in the flow's place_pins). 2300 um gives 6716 slots and placed in the flow;
config_bidir.json now uses 2300; config_bidir_die2600.json keeps the old size as fallback. Pin feasibility in OpenLane's io placer is not verified.
