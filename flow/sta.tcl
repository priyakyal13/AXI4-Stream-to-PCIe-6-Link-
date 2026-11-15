# env: NETLIST TOP CLK CORNER ; OpenSTA, no parasitics (pre-placement: wire load = 0, optimistic)
set corner $::env(CORNER)
read_liberty "$::env(PDK)/sky130_fd_sc_hd__${corner}.lib"
read_verilog $::env(NETLIST)
link_design $::env(TOP)
set clk $::env(CLK)
create_clock -name clk -period $clk [get_ports clk]
set io [expr $clk*0.2]
set_input_delay $io -clock clk [lsearch -inline -all -not -exact [all_inputs] [get_ports clk]]
set_output_delay $io -clock clk [all_outputs]
puts "===== CORNER $corner clk=$clk ====="
report_checks -path_delay max -group_count 1 -fields {fanout} -digits 3
report_checks -path_delay min -group_count 1 -digits 3 -format end
puts "WNS_MAX: [sta::worst_slack_cmd max]"
puts "WNS_MIN: [sta::worst_slack_cmd min]"
report_tns
