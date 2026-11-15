# OpenROAD pre-route flow used for A/B comparison: floorplan -> place -> repair_design -> parasitics est. -> repair_timing
# env: NETLIST TOP CLK DIE OUT
set top $::env(TOP); set clk $::env(CLK); set die $::env(DIE); set out $::env(OUT)
read_lef $::env(PDK)/sky130_fd_sc_hd.tlef
read_lef $::env(PDK)/sky130_fd_sc_hd_merged.lef
define_corners tt ss ff
read_liberty -corner tt $::env(PDK)/sky130_fd_sc_hd__tt_025C_1v80.lib
read_liberty -corner ss $::env(PDK)/sky130_fd_sc_hd__ss_100C_1v60.lib
read_liberty -corner ff $::env(PDK)/sky130_fd_sc_hd__ff_n40C_1v95.lib
read_verilog $::env(NETLIST)
link_design $top
create_clock -name clk -period $clk [get_ports clk]
set io [expr $clk*0.2]
set_input_delay $io -clock clk [lsearch -inline -all -not -exact [all_inputs] [get_ports clk]]
set_output_delay $io -clock clk [all_outputs]
initialize_floorplan -die_area "0 0 $die $die" -core_area "10 10 [expr $die-10] [expr $die-10]" -site unithd
make_tracks li1  -x_offset 0.23 -x_pitch 0.46 -y_offset 0.17 -y_pitch 0.34
make_tracks met1 -x_offset 0.17 -x_pitch 0.34 -y_offset 0.17 -y_pitch 0.34
make_tracks met2 -x_offset 0.23 -x_pitch 0.46 -y_offset 0.17 -y_pitch 0.34
make_tracks met3 -x_offset 0.34 -x_pitch 0.68 -y_offset 0.34 -y_pitch 0.68
make_tracks met4 -x_offset 0.46 -x_pitch 0.92 -y_offset 0.61 -y_pitch 0.92
make_tracks met5 -x_offset 1.70 -x_pitch 3.40 -y_offset 1.70 -y_pitch 3.40
tapcell -distance 14 -tapcell_master sky130_fd_sc_hd__tapvpwrvgnd_1
puts "STAGE: global placement"
global_placement -skip_io -density 0.4
place_pins -hor_layers met3 -ver_layers met2 -min_distance 1
global_placement -density 0.4
set_wire_rc -signal -layer met2
set_wire_rc -clock -layer met5
estimate_parasitics -placement
proc wns {c mm} { return [sta::worst_slack_corner [sta::find_corner $c] $mm] }
proc tns {c} { return [sta::total_negative_slack_corner_cmd [sta::find_corner $c] max] }
puts "=== PRE-REPAIR (placed, unbuffered) ==="
foreach c {tt ss ff} { puts "WNS_${c}_prerepair: [wns $c max]" }
puts "STAGE: repair_design"
repair_design -max_wire_length 600
estimate_parasitics -placement
puts "=== POST repair_design ==="
foreach c {tt ss ff} { puts "WNS_${c}_after_repair_design: [wns $c max]" }
puts "STAGE: repair_timing"
repair_timing -setup
estimate_parasitics -placement
puts "=== POST repair_timing ==="
foreach c {tt ss ff} {
  puts "FINAL_${c}: setup_WNS [wns $c max] setup_TNS [tns $c] hold_WNS [wns $c min]"
}
report_checks -path_delay max -corner ss -group_count 1 -fields {fanout cap slew} -digits 3
report_design_area
write_verilog $out/post_repair.v
write_def $out/post_place.def
