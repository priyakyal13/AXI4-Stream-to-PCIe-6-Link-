This directory is where `make` builds compiled simulation binaries
(`iverilog -o sim/*.out`) and writes waveform dumps during a run.

It's intentionally near-empty in this submission — the evidence you
want (pass/fail logs and waveform `.vcd` files from the actual, current
RTL) is in `../results/`. Run `make all` from the project root to
regenerate everything in this directory yourself.
