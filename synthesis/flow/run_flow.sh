#!/bin/bash
# usage: run_flow.sh <netlist> <top> <clk_ns> <die_um> <outdir>
source "$(dirname "$0")/_env.sh"
mkdir -p "$5"
NETLIST=$1 TOP=$2 CLK=$3 DIE=$4 OUT=$5 $OPENROAD -no_init -exit $FLOWDIR/flow.tcl > $5/flow.log 2>&1
grep -E "FINAL_|Design area|Error|ERROR" $5/flow.log | head -40
