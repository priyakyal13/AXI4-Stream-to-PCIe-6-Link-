#!/usr/bin/env python3
"""Software reference check for the 2384-bit framed lane protocol.

This validates the specified field packing, IEEE CRC-32 convention, 4-lane
striping and Gray decode independently of the Verilog simulator. It is NOT a
replacement for `make bidir`; run both checks before claiming RTL verification.
"""
from __future__ import annotations

import random
import zlib

DATA_BITS = 2048
DATA_BYTES = 256
DATA_CRC_BITS = 32
META_BITS = 272
META_BYTES = META_BITS // 8  # 34 bytes
FRAME_BITS = 2384
LANES = 4
SYMBOL_BITS = 2
SYMBOLS_PER_LANE = FRAME_BITS // SYMBOL_BITS // LANES  # 298
LANE_BITS = SYMBOLS_PER_LANE * SYMBOL_BITS  # 596
MAGIC = 0xA5


def crc32_reflected(data: bytes) -> int:
    return zlib.crc32(data) & 0xFFFFFFFF


def pack_meta(keep: int, last: int, beat_valid: int) -> int:
    return (
        (keep & ((1 << 256) - 1))
        | ((last & 0xF) << 256)
        | ((beat_valid & 0xF) << 260)
        | (MAGIC << 264)
    )


def encode_gray(raw: int) -> int:
    return (((raw >> 1) & 1) << 1) | (((raw >> 1) & 1) ^ (raw & 1))


def decode_gray(gray: int) -> int:
    msb = (gray >> 1) & 1
    return (msb << 1) | (msb ^ (gray & 1))


def to_lanes(frame: int) -> list[int]:
    lanes = [0] * LANES
    for symbol_idx in range(FRAME_BITS // 2):
        raw = (frame >> (symbol_idx * 2)) & 0x3
        lane = symbol_idx % LANES
        slot = symbol_idx // LANES
        lanes[lane] |= encode_gray(raw) << (slot * 2)
    return lanes


def from_lanes(lanes: list[int]) -> int:
    frame = 0
    for symbol_idx in range(FRAME_BITS // 2):
        lane = symbol_idx % LANES
        slot = symbol_idx // LANES
        gray = (lanes[lane] >> (slot * 2)) & 0x3
        frame |= decode_gray(gray) << (symbol_idx * 2)
    return frame


def make_frame(data: bytes, keep: int, last: int, beat_valid: int) -> int:
    assert len(data) == DATA_BYTES
    data_int = int.from_bytes(data, "little")
    data_crc = crc32_reflected(data)
    meta = pack_meta(keep, last, beat_valid)
    meta_bytes = meta.to_bytes(META_BYTES, "little")
    meta_crc = crc32_reflected(meta_bytes)
    return data_int | (data_crc << 2048) | (meta << 2080) | (meta_crc << 2352)


def check_frame(frame: int) -> bool:
    data_int = frame & ((1 << 2048) - 1)
    data = data_int.to_bytes(DATA_BYTES, "little")
    data_crc = (frame >> 2048) & 0xFFFFFFFF
    meta = (frame >> 2080) & ((1 << META_BITS) - 1)
    meta_crc = (frame >> 2352) & 0xFFFFFFFF
    return (
        ((meta >> 264) & 0xFF) == MAGIC
        and crc32_reflected(data) == data_crc
        and crc32_reflected(meta.to_bytes(META_BYTES, "little")) == meta_crc
    )


def main() -> None:
    # Fixed known convention check: IEEE CRC32 for ASCII "123456789".
    assert crc32_reflected(b"123456789") == 0xCBF43926
    assert (FRAME_BITS, LANE_BITS, SYMBOLS_PER_LANE) == (2384, 596, 298)

    rng = random.Random(0x5A2C2026)
    for n in range(1000):
        data = bytes(rng.getrandbits(8) for _ in range(DATA_BYTES))
        keep = rng.getrandbits(256)
        # Exercise both sparse and contiguous patterns, full and partial FLITs.
        last = rng.getrandbits(4)
        beat_valid = rng.randrange(1, 16)
        meta_fields = pack_meta(keep, last, beat_valid)
        assert meta_fields.bit_length() <= META_BITS
        frame = make_frame(data, keep, last, beat_valid)
        lanes = to_lanes(frame)
        assert all(x.bit_length() <= LANE_BITS for x in lanes)
        reconstructed = from_lanes(lanes)
        assert reconstructed == frame, f"lane round trip failed at seed case {n}"
        assert check_frame(reconstructed), f"frame CRC failed at case {n}"
        # Flip a payload bit; it must not validate.
        assert not check_frame(reconstructed ^ 1), f"corruption not detected at case {n}"
        # Flip a metadata bit; metadata CRC must detect it too.
        assert not check_frame(reconstructed ^ (1 << 2080)), f"metadata corruption not detected at case {n}"

    print("PASS: protocol reference checks = 1000")
    print("PASS: 2384-bit frame / four 596-bit lanes / 2-bit Gray symbols")
    print("PASS: data CRC and metadata CRC detect injected corruption")
    print("NOTE: Run `make bidir` to verify the RTL implementation itself.")


if __name__ == "__main__":
    main()
