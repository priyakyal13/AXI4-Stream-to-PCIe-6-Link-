# OpenLane 2.3.10 commands (this configuration HAS been run by the team: results in final_outputs and reports/openlane_v7_results.md)
```bash
cd <project root>
python3 -m openlane --dockerized --run-tag v7_2300_20ns physical_design/config_bidir.json 2>&1 | tee physical_design/run_v7_2300.log
python3 -m openlane --dockerized --run-tag v7_2600_20ns physical_design/config_bidir_die2600.json 2>&1 | tee physical_design/run_v7_2600.log   # fallback
```
Metrics to extract (runs/<tag>/final/metrics.json and reports): timing__setup__ws, timing__setup__tns, timing__hold__ws, timing__hold__tns
(all corners), route__antenna_violation__count, antenna__violating__nets/pins, design__instance__area, design__max_slew_violation__count,
design__max_cap_violation__count, design__max_fanout_violation__count, route__drc_errors, magic/klayout DRC, LVS, power__total,
io placement success. Also check the worst setup path startpoint/endpoint and whether any async recovery/removal path is critical.
Report antenna and timing only from these runs (see reports/openlane_v7_results.md for the 2300 um result). If 2300 um fails pin placement, use the 2600 config.
Antenna proxy (synthesis/flow/grt_ant.tcl) was written earlier and was NOT run in this session.
