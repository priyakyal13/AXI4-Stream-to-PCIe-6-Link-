# Bidirectional RTL extension and verification plan

## Purpose

The original design contains a TX path only. A receive module alone would not be enough to reconstruct the AXI-Stream source semantics because the previous FLIT frame only carried data and data CRC. The extension adds explicit, CRC-protected framing metadata while retaining the original TX-only top for baseline comparison.

## Framed word format

The 2384-bit frame, ordered from least significant to most significant, is:

| Bit range | Width | Field |
|---|---:|---|
| 0–2047 | 2048 | 256-byte data FLIT |
| 2048–2079 | 32 | IEEE CRC-32 over data FLIT |
| 2080–2335 | 256 | one TKEEP bit per data byte, grouped as four 64-bit masks |
| 2336–2339 | 4 | TLAST per original 512-bit beat |
| 2340–2343 | 4 | valid-beat mask; excludes zero-padding beats from RX output |
| 2344–2351 | 8 | magic/version byte 0xA5 |
| 2352–2383 | 32 | IEEE CRC-32 over the 272-bit metadata field |

The frame maps over four lanes. Symbols are 2 bits each, Gray encoded using the same mapping as the original Layer 4 module. Each lane carries 298 symbols, i.e. 596 bits per frame. This is a synchronous digital-link model rather than a physical serial lane implementation.

## RX behavior

1. Accept a frame only while RX is idle.
2. Invert the two-bit Gray mapping and de-stripe the lane symbols into the frame.
3. Check the metadata magic byte and metadata CRC.
4. Check the data CRC across four 512-bit words, one word per cycle.
5. On any check failure, increment the bad-frame counter, pulse `rx_error`, and drop the frame.
6. On a passing frame, emit only valid beats and reconstruct each beat's data, TKEEP, and TLAST. Invalid/padded positions are skipped. AXI output backpressure holds the current beat stable.

`rx_error_code`: 1 = data CRC failure, 2 = metadata CRC failure, 3 = invalid magic/version byte.

## Verification collateral

- `tb/tb_top_4layer_bidir.v`: integrated TX-to-RX loopback, exact AXI-Stream beat scoreboard, sparse TKEEP, packet lengths 1/2/4/5 beats, multiple-FLIT packet, controlled output stalls, a flipped payload bit, error detection and clean recovery.
- `scripts/check_bidir_protocol.py`: 1000 randomized software checks for frame packing, lane mapping, Gray coding, and CRC detection.
- Run `make bidir` with Icarus Verilog; its completion is required before claiming RTL simulation pass.
- Run `make all` to rerun existing directed regressions plus the bidirectional suite.

## Scope limitations

This extension implements a simplified synchronous digital link. It is not a complete PCIe 6.0 FLIT/FEC pipeline, actual SerDes, link training/recovery, flow-control DLLPs, or a full memory-mapped AXI4 bridge. The original design uses AXI4-Stream TX input sources. The full bidirectional top is functionally integrated but requires HDL simulation and separate physical-design evaluation. The physical-design configuration `physical_design/config_bidir.json` is provided as a starting point only; its GDSII/DRC/LVS/timing results have not been generated or verified for this new top.
