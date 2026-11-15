# OpenLane 2.3.10 result — pd_top_bidir v7 (config_bidir.json, 2300 x 2300 um, 20 ns)
Source: `physical_design/final_outputs/metrics.json`, log `physical_design/run_v7_2300.log`.

| Metric | Value |
|---|---|
| Setup WS (max_ss / nom_ss / min_ss) | +3.159 / +3.577 / +4.076 ns; tt +8.82 ns; ff +10.84 ns; TNS 0; setup violations 0 |
| Hold WS (max_ss / nom_ss / min_ss) | −0.938 / −0.740 / −0.516 ns; tt +0.32 ns; ff +0.11 ns |
| Hold TNS (max_ss) / hold violation count | −856.4 ns / 5636; hold buffers inserted: 0 |
| Clock skew worst setup / hold | +0.519 / −0.507 ns |
| Antenna | 34 nets / 35 pins; 278 diodes; antenna-class cells 54,996 |
| DRC (route / Magic / KLayout) | 0 / 0 / 0 |
| LVS | 0 errors (all differences 0) |
| Max slew / cap / fanout violations | 8227 / 710 / 3602 |
| Instances / stdcell area / utilization | 187,011 / 930,505 um2 / 17.86 % |
| Wirelength / vias | 5,446,526 um / 481,287 |
| Power total / switching / internal / leakage | 0.570 / 0.349 / 0.221 / 1.2e-6 (as reported) |
| IO count | 6516 (6514 placed at floorplan) |

Interpretation: timing closes for setup at every corner; hold fails at the SS corners and the violation count is large. Hold repair did not insert any hold buffers in this run, so the next step is to inspect the hold paths in the OpenLane run directory (STA reports of the max_ss corner) and decide whether they are IO-constrained paths (input delay 4 ns, clock uncertainty 0.25 ns in the SDC) or internal paths, and then rerun with hold repair enabled/tuned. Antenna, max-slew/cap/fanout counts are likewise not clean.
