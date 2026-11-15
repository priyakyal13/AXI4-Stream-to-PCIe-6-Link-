#!/bin/bash
# Full regression for the bidirectional design.  Usage: scripts/run_regression.sh [seeds, default 10]
# Writes results/regression_summary.log; exit status 0 only if every step passed.
cd "$(dirname "$0")/.." || exit 2
NSEEDS=${1:-10}
mkdir -p sim results
LOG=results/regression_summary.log; : > $LOG
fail=0
step() {   # step <name> <grep-pattern-that-must-match> <cmd...>
  name=$1; pat=$2; shift 2
  out=$("$@" 2>&1); rc=$?
  line=$(echo "$out" | grep -E "$pat" | tail -1)
  if [ $rc -eq 0 ] && [ -n "$line" ] && ! echo "$out" | grep -qE "^FAIL|TESTS FAILED: [1-9]|failures=[1-9]|fails=[1-9]"; then st=PASS; else st=FAIL; fail=1; fi
  echo "$st  $name :: $line" | tee -a $LOG
}
for t in layer1 layer2 layer3 layer4 top; do step "make $t" "TESTS PASSED" make $t; done
step "make bidir" "BIDIR_TEST_SUMMARY" make bidir
step "make protocol-check" "protocol reference checks" make protocol-check
step "random random  N=500 SEED=1"  "TESTS PASSED" make random PROFILE=random  N=500 STALL=40 GAP=3 SEED=1
step "random network N=300 SEED=11" "TESTS PASSED" make random PROFILE=network N=300 STALL=0  GAP=0 SEED=11
step "random jumbo   N=100 SEED=17" "TESTS PASSED" make random PROFILE=jumbo   N=100 STALL=20 GAP=2 SEED=17
step "random ml      N=100 SEED=23" "TESTS PASSED" make random PROFILE=ml      N=100 STALL=0  GAP=0 SEED=23
step "make rxsb"  "RXSB"  make rxsb
step "make crceq" "meta-CRC|TX framed" make crceq
# seed sweep with varying source gap / sink backpressure
GAPS=(2 0 0 5 1 8 3 0 4 2 6 0 1 3 7)
BPS=(70 100 30 50 90 20 70 60 100 40 80 10 95 25 55)
for ((s=1; s<=NSEEDS; s++)); do
  g=${GAPS[$(( (s-1) % 15 ))]}; b=${BPS[$(( (s-1) % 15 ))]}
  step "toprand SEED=$s gap=$g bp=$b" "PASS: BIDIR random" make toprand SEED=$s NPK=40 TGAP=$g TBP=$b
done
echo "REGRESSION_STATUS: $([ $fail -eq 0 ] && echo ALL_PASS || echo FAILURES)" | tee -a $LOG
exit $fail
