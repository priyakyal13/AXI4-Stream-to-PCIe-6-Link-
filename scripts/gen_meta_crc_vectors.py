#!/usr/bin/env python3
"""zlib-derived vectors for the 272-bit metadata CRC: sim/meta_crc_vec.hex = '<272-bit data hex> <crc hex>' per line."""
import random, zlib, sys
rng = random.Random(int(sys.argv[1]) if len(sys.argv) > 1 else 7)
vecs = [0, (1 << 272) - 1] + [1 << i for i in range(272)] + [rng.getrandbits(272) for _ in range(3000)]
with open("sim/meta_crc_vec.hex", "w") as f:
    for v in vecs:
        f.write(f"{v:068x} {zlib.crc32(v.to_bytes(34, 'little')):08x}\n")
print("wrote", len(vecs), "vectors")
