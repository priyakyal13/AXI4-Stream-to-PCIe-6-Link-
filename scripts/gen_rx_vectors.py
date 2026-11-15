#!/usr/bin/env python3
"""Independent reference-model vector generator for the framed RX (uses zlib.crc32 only).

Writes, under sim/:
  rx_frames.hex    4 lines per frame: lane0..lane3, 596-bit Gray-encoded lane words (149 hex digits)
  rx_expect.hex    one line per frame: <status:1 hex> <nbeats:1 hex> ; status 0=good,1=data CRC,2=meta CRC,3=bad magic
  rx_beats.hex     for every beat of every GOOD frame, in order: keep(16 hex) last(1) data(128 hex), one beat/line
  rx_params.vh     `define RX_NFRAMES N
The expected status is derived from frame CONTENT with the documented priority
(bad magic > metadata CRC > data CRC), not from how the frame was mutated.
Usage: gen_rx_vectors.py [seed] [nframes]
"""
import random, sys, zlib
seed = int(sys.argv[1]) if len(sys.argv) > 1 else 1
N = int(sys.argv[2]) if len(sys.argv) > 2 else 600
rng = random.Random(seed)
MAGIC = 0xA5
def gray_enc(r): return ((r >> 1) & 1) << 1 | (((r >> 1) & 1) ^ (r & 1))
def to_lanes(frame):
    lanes = [0]*4
    for s in range(1192):
        raw = (frame >> (2*s)) & 3
        lanes[s % 4] |= gray_enc(raw) << (2*(s//4))
    return lanes
def fields(frame):
    d = frame & ((1<<2048)-1); dc = (frame>>2048) & 0xFFFFFFFF
    m = (frame>>2080) & ((1<<272)-1); mc = (frame>>2352) & 0xFFFFFFFF
    return d, dc, m, mc
def status(frame):
    d, dc, m, mc = fields(frame)
    if ((m>>264)&0xFF) != MAGIC: return 3
    if zlib.crc32(m.to_bytes(34,'little')) != mc: return 2
    if zlib.crc32(d.to_bytes(256,'little')) != dc: return 1
    return 0
def make(data, keep, last, bv, magic=MAGIC):
    m = keep | (last<<256) | (bv<<260) | (magic<<264)
    return int.from_bytes(data,'little') | (zlib.crc32(data)<<2048) | (m<<2080) | (zlib.crc32(m.to_bytes(34,'little'))<<2352)
def rand_keep():
    k = 0
    for b in range(4):
        mode = rng.choice(['full','prefix','sparse','zero','one'])
        if mode=='full': w=(1<<64)-1
        elif mode=='prefix': w=(1<<rng.randint(1,64))-1
        elif mode=='sparse': w=rng.getrandbits(64)
        elif mode=='zero': w=0
        else: w=1<<rng.randrange(64)
        k |= w << (64*b)
    return k
def good_frame():
    data = bytes(rng.getrandbits(8) for _ in range(256))
    bv = rng.choice([0xF,0xF,0x1,0x3,0x7,0x5,0xA,0x0,rng.getrandbits(4)])   # incl. odd masks and all-invalid
    return make(data, rand_keep(), rng.getrandbits(4), bv)
frames=[]
kinds=[]
for i in range(N):
    f = good_frame(); k='good'
    r = rng.random()
    if r < 0.45:
        pass
    elif r < 0.55:   f ^= 1 << rng.randrange(0,2048); k='data_bit'
    elif r < 0.60:   f ^= 1 << rng.randrange(2048,2080); k='dcrc_bit'
    elif r < 0.68:   f ^= 1 << rng.randrange(2080,2336); k='keep_bit'
    elif r < 0.72:   f ^= 1 << rng.randrange(2336,2344); k='last/valid_bit'
    elif r < 0.78:   f ^= 1 << rng.randrange(2344,2352); k='magic_bit'
    elif r < 0.83:   f ^= 1 << rng.randrange(2352,2384); k='mcrc_bit'
    elif r < 0.90:
        for _ in range(rng.randint(2,9)): f ^= 1 << rng.randrange(0,2384)
        k='multi'
    elif r < 0.93:   f = rng.getrandbits(2384); k='garbage'
    elif r < 0.95:   f = 0; k='zeros'
    elif r < 0.97:   f = (1<<2384)-1; k='ones'
    else:
        data=bytes(rng.getrandbits(8) for _ in range(256))
        f = make(data, rand_keep(), rng.getrandbits(4), rng.getrandbits(4), magic=rng.choice([0x00,0xA4,0x5A,0xFF,0xA7])); k='wrong_magic_valid_crc'
    frames.append(f); kinds.append(k)
fh=open('sim/rx_frames.hex','w'); eh=open('sim/rx_expect.hex','w'); bh=open('sim/rx_beats.hex','w')
counts={0:0,1:0,2:0,3:0}; nb=0
for f in frames:
    for l in to_lanes(f): fh.write(f"{l:0149x}\n")
    st=status(f); counts[st]+=1
    beats=[]
    if st==0:
        d,dc,m,mc=fields(f)
        keep=m&((1<<256)-1); last=(m>>256)&0xF; bv=(m>>260)&0xF
        for b in range(4):
            if (bv>>b)&1:
                kb=(keep>>(64*b))&((1<<64)-1)
                raw=(d>>(512*b))&((1<<512)-1)
                # RX returns the buffered data as-is (TX zeroes TKEEP=0 bytes; this model keeps raw bytes)
                beats.append((kb,(last>>b)&1,raw))
    eh.write(f"{st:x} {len(beats):x}\n")
    for kb,l,raw in beats: bh.write(f"{kb:016x} {l:x} {raw:0128x}\n"); nb+=1
open('sim/rx_params.vh','w').write(f"`define RX_NFRAMES {N}\n`define RX_NBEATS {nb}\n")
print(f"seed={seed} frames={N} good={counts[0]} dataCRC_bad={counts[1]} metaCRC_bad={counts[2]} magic_bad={counts[3]} good_beats={nb}")
