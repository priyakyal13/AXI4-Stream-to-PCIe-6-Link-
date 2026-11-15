#!/usr/bin/env python3
"""Cross-check the Layer 4 striping/Gray index math (new generate form)
against the Stage-1 loop semantics, on random FLITs."""
import random
GRAY = {0:0, 1:1, 2:3, 3:2}
def stage1(word):                       # symbol i -> lane i%4, slot i//4
    lanes = [0]*4
    for i in range(1040):
        s = (word >> (2*i)) & 3
        lanes[i % 4] |= GRAY[s] << (2*(i // 4))
    return lanes
def stage2(word):                       # new generate formulas
    lanes = [0]*4
    for p in range(260):
        for l in range(4):
            raw = (word >> ((p*4 + l)*2)) & 3
            g = ((raw >> 1) << 1) | ((raw >> 1) ^ (raw & 1))   # {r1, r1^r0}
            lanes[l] |= g << (p*2)
    return lanes
random.seed(7)
for _ in range(500):
    w = random.getrandbits(2080)
    assert stage1(w) == stage2(w)
print("layer4 mapping check: new generate form == Stage-1 semantics on 500 random FLITs  OK")
