# env: DEF TOP OUT CLK ; global-route estimate + antenna check (proxy; no diode repair unless REPAIR=1)
read_lef $::env(PDK)/sky130_fd_sc_hd.tlef
read_lef $::env(PDK)/sky130_fd_sc_hd_merged.lef
read_liberty $::env(PDK)/sky130_fd_sc_hd__tt_025C_1v80.lib
read_def $::env(DEF)
set_routing_layers -signal met1-met5 -clock met1-met5
set_global_routing_layer_adjustment met1 0.8
set_global_routing_layer_adjustment met2 0.7
set_global_routing_layer_adjustment met3 0.7
set_global_routing_layer_adjustment met4 0.7
set_global_routing_layer_adjustment met5 0.7
puts "STAGE: global_route"
global_route -guide_file $::env(OUT)/route.guide -congestion_iterations 30 -allow_overflow
puts "STAGE: check_antennas (no diode repair)"
check_antennas -verbose
if {[info exists ::env(REPAIR)]} {
  puts "STAGE: repair_antennas"
  repair_antennas sky130_fd_sc_hd__diode_2
  puts "STAGE: check_antennas after repair"
  check_antennas -verbose
}
