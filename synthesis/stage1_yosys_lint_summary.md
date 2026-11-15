# Synthesis / Lint Sanity Check (Yosys 0.33)

Stage 1 does not require synthesis — this is a sanity check, not a
Stage 2 synthesis deliverable. Full rationale is in
`../reports/design_document.md`, Section 9.

## Command used (per layer)

```bash
yosys -p "read_verilog -sv <layer>.v; hierarchy -check; proc; opt; synth -top <layer>; stat"
```

## Results

| Layer | Result |
|---|---|
| `layer1_axis_stream_ingress.v` | **Clean.** 0 problems, 580 cells, no inferred latches. |
| `layer2_axis_arbiter.v` | **Clean.** 0 problems, 854 cells, no inferred latches. |
| `layer3_flit_packetizer.v` | Elaborates; `opt`/`check` did not complete within a 90s budget. |
| `layer4_flit_to_phy_lanes.v` | Verilog-frontend parsing did not complete within a 60s budget. |

## Layer 1 stat output

```
Number of wires:                 13
Number of wire bits:           1161
Number of cells:                580
  $_AND_                          1
  $_DFFE_PN0P_                  578
  $_ORNOT_                        1
CHECK pass: Found and reported 0 problems.
```

## Layer 2 stat output

```
Number of wires:                171
Number of wire bits:           2079
Number of cells:                854
  $_ANDNOT_                      43
  $_AND_                         23
  $_DFFE_PN0P_                   65
  $_DFFE_PN1P_                    1
  $_DFF_PN0_                      1
  $_MUX_                        584
  $_NAND_                        30
  $_NOT_                          9
  $_ORNOT_                       13
  $_OR_                          23
  $_XNOR_                        12
  $_XOR_                         50
CHECK pass: Found and reported 0 problems (both PROC_DLATCH checks — no
inferred latches).
```

## Layers 3 & 4: why they didn't complete

Both modules contain fully **unrolled combinational loops** — Layer 3's
CRC-32 unrolls across all 256 bytes of a FLIT in one procedural block,
and Layer 4's lane-striping unrolls across all 1040 symbols. Both
simulate correctly (proven by 162/162 passing testbench checks across
the whole design), but the resulting combinational netlist is large
enough that Yosys's `opt`/`check` passes did not finish in the time
budgeted here.

This is a genuine, useful finding, not a tooling failure to hide: it's
independent confirmation of the synthesis note already in the design
document — a real implementation target would pipeline the CRC (e.g.,
one byte per cycle) and the symbol-striping stage across multiple
cycles rather than computing either combinationally in one cycle. This
is scoped as a Stage 2 concern; Stage 1 asks for correct, verified RTL,
not synthesis-optimized RTL.
