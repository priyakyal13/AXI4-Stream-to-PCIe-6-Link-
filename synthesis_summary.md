# Stage 2 Synthesis Summary

This file supersedes the historical Stage 1 synthesis note. The figures below are user-run Yosys results recorded in `STAGE2_NOTES.md`; they were not rerun in the packaging environment because Yosys is unavailable here.

## Reported optimization results

| Metric | Stage 1 L3 baseline | Stage 2 L3 rewrite | Layer 4 |
|---|---:|---:|---:|
| Synthesis outcome | Completed but very large | Completed | Stage 1 synthesis did not finish in the previous budget; Stage 2 completed |
| Cell count | 31,333 | 9,838 (reported checkpoint) | 3,125 |
| Flip-flops | 4,134 | 2,087 | 2,081 |
| XOR/XNOR cells | 18,419 | about 5,030 | — |
| Synthesis time | 229 s | about 9 s | about 0.5 s |

The recorded Layer 3 figures are checkpoint results (v4 as listed in `STAGE2_NOTES.md`). The exact current v5 Yosys result should be rerun and captured before claiming that same number specifically for v5.

## Commands

```bash
yosys -p "read_verilog -sv rtl/crc32_d512.v rtl/layer3_flit_packetizer.v; synth -flatten -top layer3_flit_packetizer; stat"
yosys -p "read_verilog -sv rtl/layer4_flit_to_phy_lanes.v; synth -flatten -top layer4_flit_to_phy_lanes; stat"
```

Record the Yosys version, full command, elapsed time, `stat` output, and source revision for each run.

## Interpretation

The primary Layer 3 optimization replaces a single huge FLIT-wide combinational CRC cone with incremental 512-bit CRC updates and zero-skip logic for early packet ends. Layer 4 was rewritten to use explicit lane mapping/Gray coding that Yosys can synthesize. These results are structural/synthesis results, not routed area or proof of PCIe 6.0 compliance.

Historical Stage 1 analysis is preserved in `stage1_yosys_lint_summary.md` for provenance only.
