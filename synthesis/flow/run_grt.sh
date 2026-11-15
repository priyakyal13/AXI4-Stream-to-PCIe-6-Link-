#!/bin/bash
# usage: run_grt.sh <def> <top> <outdir>   (env REPAIR=1 also runs repair_antennas with diode_2)
source "$(dirname "$0")/_env.sh"
mkdir -p "$3"
DEF=$1 TOP=$2 OUT=$3 $OPENROAD -no_init -exit $FLOWDIR/grt_ant.tcl > $3/grt.log 2>&1
grep -E "STAGE|Found|violat|Error|ERROR|Total" $3/grt.log | head -20
