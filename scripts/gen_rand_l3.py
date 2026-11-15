#!/usr/bin/env python3
"""
Random-stimulus + golden-model generator for the Layer 3 packetizer.

usage: python3 scripts/gen_rand_l3.py [seed] [num_packets] [profile]
  profile: random (default) | network (IMIX-like Ethernet frames) | jumbo (9000 B) | ml (INT8 tensor transfers)

Writes into sim/ :
  rand_stim_data.hex / rand_stim_keep.hex / rand_stim_last.hex   (one line per input beat)
  rand_exp_data.hex / rand_exp_crc.hex / rand_exp_part.hex       (one line per expected FLIT)
  rand_params.vh                                                 (NBEATS, NFLITS)

Golden model (independent of the RTL):
  * TKEEP=0 bytes become 0x00 (not compacted)
  * a FLIT closes after 4 beats, or early on TLAST (zero padded, partial=1)
  * CRC = zlib.crc32 (IEEE 802.3) over the 256-byte little-endian FLIT
"""
import os, random, sys, zlib

seed = int(sys.argv[1]) if len(sys.argv) > 1 else 1
npk  = int(sys.argv[2]) if len(sys.argv) > 2 else 500
profile = sys.argv[3] if len(sys.argv) > 3 else "random"
rng = random.Random(seed)
FULL = (1 << 64) - 1

def rand_keep(is_last):
    r = rng.random()
    if not is_last:
        return FULL if r < 0.8 else (rng.getrandbits(64) or 1)
    if r < 0.15: return FULL
    if r < 0.75:                                   # contiguous low bytes
        return (1 << rng.randint(1, 64)) - 1
    return rng.getrandbits(64) or 1                # arbitrary mask

beats = []                                         # (data, keep, last)
payload_bytes = 0

def packet_bytes():
    if profile == "network":                       # IMIX-like: 7:4:1 of 64 B / 594 B / 1518 B
        return rng.choices([64, 594, 1518], weights=[58, 33, 9])[0]
    if profile == "jumbo":
        return 9000
    if profile == "ml":                            # weight loads / activation tensors (INT8)
        return rng.choices([4096, 16384, 65536], weights=[60, 30, 10])[0]
    return None

for _ in range(npk):
    nbytes = packet_bytes()
    if nbytes is None:                             # fully random profile
        n = rng.choice([1,1,2,2,3,4,4,5,6,8,9])
        for b in range(n):
            last = (b == n - 1)
            k = rand_keep(last)
            beats.append((rng.getrandbits(512), k, last))
            payload_bytes += bin(k).count("1")
    else:
        n = (nbytes + 63) // 64
        for b in range(n):
            last = (b == n - 1)
            rem = nbytes - 64 * b
            k = FULL if rem >= 64 else (1 << rem) - 1
            beats.append((rng.getrandbits(512), k, last))
            payload_bytes += min(rem, 64)

def mask(data, keep):
    out = 0
    for j in range(64):
        if (keep >> j) & 1:
            out |= ((data >> (8 * j)) & 0xFF) << (8 * j)
    return out

flits = []                                         # (data2048, crc, partial)
words, idx = [0] * 4, 0
def emit(partial):
    global words, idx
    d = sum(w << (512 * k) for k, w in enumerate(words))
    flits.append((d, zlib.crc32(d.to_bytes(256, "little")), partial))
    words, idx = [0] * 4, 0

for data, keep, last in beats:
    words[idx] = mask(data, keep)
    if last:
        emit(partial=(idx != 3))
    elif idx == 3:
        emit(partial=False)
    else:
        idx += 1
assert idx == 0, "stream must end on TLAST"

os.makedirs("sim", exist_ok=True)
def w(name, lines): open(f"sim/{name}", "w").write("\n".join(lines) + "\n")
w("rand_stim_data.hex", [f"{d:0128x}" for d, _, _ in beats])
w("rand_stim_keep.hex", [f"{k:016x}" for _, k, _ in beats])
w("rand_stim_last.hex", [str(int(l)) for _, _, l in beats])
w("rand_exp_data.hex",  [f"{d:0512x}" for d, _, _ in flits])
w("rand_exp_crc.hex",   [f"{c:08x}" for _, c, _ in flits])
w("rand_exp_part.hex",  [str(int(p)) for _, _, p in flits])
open("sim/rand_params.vh", "w").write(
    f"localparam NBEATS = {len(beats)};\nlocalparam NFLITS = {len(flits)};\n")
print(f"profile={profile} seed={seed}: {npk} packets -> {len(beats)} beats -> {len(flits)} FLITs "
      f"({sum(p for _,_,p in flits)} partial); payload={payload_bytes} B, "
      f"FLIT payload efficiency={100.0*payload_bytes/(256*len(flits)):.1f}%")
