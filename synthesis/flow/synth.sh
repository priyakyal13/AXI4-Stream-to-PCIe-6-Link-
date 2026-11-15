#!/bin/bash
# usage: synth.sh <top> <outdir> <clk_ns> <rtl files...>
# Generic Yosys -> SKY130HD netlist flow (abc timing-driven), mirrors OpenLane's synthesis step in spirit.
TOP=$1; OUT=$2; CLK=$3; shift 3
LIB=${PDK:-/opt/pdk}/sky130_fd_sc_hd__tt_025C_1v80.lib
mkdir -p $OUT
PS=$(python3 -c "print(int($CLK*1000))")
cat > $OUT/abc.script <<EOF
strash
ifraig
scorr
dc2
dret
strash
&get -n
&dch -f
&nf {D}
&put
buffer -c
upsize {D}
dnsize {D}
EOF
yosys -q -l $OUT/yosys.log -p "
read_verilog -sv $*
hierarchy -check -top $TOP
synth -flatten -top $TOP
opt -purge
dfflibmap -liberty $LIB
opt
abc -liberty $LIB -D $PS
hilomap -singleton -hicell sky130_fd_sc_hd__conb_1 HI -locell sky130_fd_sc_hd__conb_1 LO
opt_clean -purge
tee -o $OUT/stat.txt stat -liberty $LIB
write_verilog -noattr -noexpr -nohex -nodec $OUT/${TOP}_netlist.v
" 
tail -40 $OUT/stat.txt
