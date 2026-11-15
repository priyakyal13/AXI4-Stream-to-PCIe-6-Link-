#!/bin/bash
# usage: run_sta.sh <netlist> <top> <clk_ns> <outprefix>   (no parasitics: optimistic, synthesis-level check)
source "$(dirname "$0")/_env.sh"
for c in tt_025C_1v80 ss_100C_1v60 ff_n40C_1v95; do
 NETLIST=$1 TOP=$2 CLK=$3 CORNER=$c $OPENSTA -no_init -exit $FLOWDIR/sta.tcl > $4_$c.rpt 2>&1
 echo "$c: $(grep -E 'WNS_(MAX|MIN)' $4_$c.rpt | tr '\n' ' ')"
done
