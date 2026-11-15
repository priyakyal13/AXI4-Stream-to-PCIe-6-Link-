# AXI4 (Master & Slave) to PCIe 6 Link — Technical Design Document

**SARCathon 2026 — Semiconductor Challenge**  
**Stage 1: RTL Design & Functional Verification**

---

## 1. Executive Summary

This project implements a synthesizable RTL datapath representing a scoped digital portion of the SARCathon 2026 AXI4/AXI4-Stream to PCIe 6 reference architecture. 

The implemented design accepts data from two independent 512-bit AXI4-Stream sources. These sources compete for a single downstream datapath. A packet-atomic round-robin arbiter selects one source at a time and prevents interleaving of beats belonging to different packets. The selected stream then passes through a one-beat AXI4-Stream register slice, followed by a link-layer packetizer that groups four 512-bit beats into a fixed 256-byte FLIT and appends a CRC-32 value. The resulting 2080-bit FLIT-plus-CRC payload is then converted into 2-bit symbols, distributed across four lanes using round-robin lane striping, and Gray-coded for a digital PAM4-oriented PHY interface.

The implementation is divided into four RTL layers corresponding to the supplied reference architecture:
*   AXI4/AXI4-Stream interface and ingress buffering
*   Interconnect and arbitration
*   Link-layer FLIT packetization and CRC generation
*   PCIe protocol-to-PHY digital lane processing

Each layer is independently testable and is also integrated into a complete four-layer datapath. 

The final verification environment contains 162 passing checks across module-level and integrated verification, with zero observed packet-atomicity violations in the arbitration monitor. The project includes RTL source files, directed/self-checking testbenches, simulation scripts, waveforms, verification logs, a reproducible Makefile, and implementation notes.

---

## 2. Problem Statement

The SARCathon 2026 Semiconductor Challenge asks participants to develop RTL representing an AXI4/AXI4-Stream to PCIe 6 link architecture.

The supplied architecture addresses high-throughput movement of streaming data between SoC/accelerator-side interfaces and a PCIe-based host-side link. Typical motivating workloads include:
*   **Network packet processing**, where packet-processing engines and SmartNIC datapaths produce continuous packet streams.
*   **Machine-learning acceleration**, where accelerator pipelines generate or consume large streams of weights, activations, or pixel data.

The reference architecture contains four major functional stages:
1.  AXI4/AXI4-Stream interface
2.  Interconnect layer with crossbar and arbitration
3.  Link layer for packetization and error-handling concepts
4.  PCIe protocol-to-PHY layer

The challenge explicitly permits Stage-1 teams to select a meaningful and achievable subset of the complete architecture, with emphasis on correct RTL design, clean interfaces, functional integration, and evidence-based verification.

---

## 3. Objective

The objective of this implementation is to build and verify a complete digital datapath covering the principal functions of all four reference-architecture layers. 

The implementation specifically demonstrates:
*   Multi-source AXI4-Stream arbitration
*   Packet-atomic ownership of a shared downstream channel
*   AXI4-Stream register slicing and backpressure handling
*   Fixed-size 256-byte FLIT formation
*   TKEEP-aware byte masking and zero padding
*   CRC-32 generation
*   Conversion of FLIT data plus CRC into 2-bit symbols
*   Four-lane round-robin symbol striping
*   2-bit Gray coding for PAM4-oriented digital symbols
*   End-to-end integration from two AXI-Stream sources to four lane outputs
*   Module-level and integrated functional verification

---

## 4. Selected Implementation Scope

The implementation maps the challenge reference architecture to the following RTL modules.

| Reference Layer | Implemented Function | RTL Module |
| :--- | :--- | :--- |
| **AXI4 / AXI4-Stream Interface** | Streaming ingress and register buffering | `layer1_axis_stream_ingress.v` |
| **Interconnect Layer** | Two-master packet-atomic arbitration | `layer2_axis_arbiter.v` |
| **Link Layer** | 256-byte FLIT packetization and CRC-32 | `layer3_flit_packetizer.v` |
| **PCIe Protocol-to-PHY Layer** | Lane striping and Gray-coded symbols | `layer4_flit_to_phy_lanes.v` |

The four modules are integrated in:  
`top_4layer_true_split.v`

The implementation is intentionally scoped for Stage 1. It demonstrates the central mechanisms of the reference architecture without attempting to implement a complete PCIe controller, physical SerDes, analog PAM4 voltage generation, or generalized multi-master crossbar.

---

## 5. Top-Level Architecture

The complete datapath is:

```text
                    AXI4-Stream Master 0
                             |
                             |
                             v
                      +-------------+
                      |             |
                      |   Layer 2   |
                      |   Arbiter   |
                      |             |
                      +------+------+
                             |
                    AXI4-Stream stream
                             |
                             v
                      +-------------+
                      |   Layer 1   |
                      | Register    |
                      |   Slice     |
                      +------+------+
                             |
                       512-bit stream
                             |
                             v
                      +-------------+
                      |   Layer 3   |
                      | FLIT + CRC  |
                      +------+------+
                             |
                       2080-bit FLIT
                             |
                             v
                      +-------------+
                      |   Layer 4   |
                      |  Striping + |
                      | Gray Coding |
                      +--+--+--+----+
                         |  |  |  |
                        L0 L1 L2 L3


                    AXI4-Stream Master 1
                             |
                             +---------------------> Layer 2
```

Layer 2 provides the shared-channel arbitration. Layer 1 isolates timing and provides one-beat buffering. Layer 3 converts the streaming beat sequence into fixed-size FLIT units. Layer 4 converts each FLIT into the digital lane-symbol representation consumed at the PHY boundary.

---

## 6. Data-Width and Framing Relationships

The design uses a 512-bit AXI4-Stream datapath. A 512-bit beat contains:  
**512 bits / 8 = 64 bytes**

The target FLIT size is 256 bytes. Therefore:  
**256 bytes / 64 bytes per beat = 4 beats per FLIT**

Equivalently:  
**4 × 512 bits = 2048 data bits**

The link-layer FLIT therefore contains:
```text
Data              = 2048 bits
CRC-32            =   32 bits
                  -----------
FLIT + CRC        = 2080 bits
```

The protocol-to-PHY layer interprets the 2080-bit result as 2-bit symbols:  
**2080 / 2 = 1040 symbols**

With four lanes:  
**1040 / 4 = 260 symbols per lane**

Thus every complete output transfer contains:
*   Lane 0 = 260 symbols
*   Lane 1 = 260 symbols
*   Lane 2 = 260 symbols
*   Lane 3 = 260 symbols

---

## 7. Layer 1 — AXI4-Stream Ingress Register Slice

### 7.1 Purpose
Layer 1 is implemented in: `layer1_axis_stream_ingress.v`

Its purpose is to provide a one-beat register slice between the arbiter and the downstream packetizer. The register slice provides:
*   one-beat storage
*   timing isolation
*   correct AXI4-Stream valid/ready behavior
*   propagation of TDATA, TKEEP, and TLAST
*   support for downstream backpressure

The layer does not interpret packet contents or packet boundaries. TLAST is preserved for the downstream link layer.

### 7.2 AXI4-Stream Handshake
The input ready signal follows:  
`s_tready = m_tready | !m_tvalid`

This means that the module can accept an input beat when either:
1.  The downstream stage is ready to consume the currently stored beat, or
2.  The register is currently empty.

If the register already contains a valid beat and the downstream stage is stalled, `s_tready` is deasserted to prevent overwriting the stored transaction. This provides full-throughput behavior when the downstream stage remains ready.

### 7.3 Example
Consider a continuous sequence of four beats:
```text
Input:
B0 → B1 → B2 → B3

Downstream ready:
1    1    1    1
```
The register slice can accept one new beat every cycle while forwarding the previously stored beat. Under normal operation, the stage therefore introduces approximately one cycle of pipeline latency while preserving back-to-back throughput.

### 7.4 Backpressure Behavior
When `m_tready = 0` and `m_tvalid = 1`, the current output transaction remains stable and `s_tready = 0`. The upstream source must therefore hold its current transaction until the downstream stage becomes ready again. This prevents data loss and overwriting.

### 7.5 Verification
The Layer-1 testbench verifies:
*   reset behavior
*   basic in-order transfer
*   multi-beat bursts
*   continuous back-to-back operation
*   backpressure
*   output-data stability during stalls
*   TLAST preservation and TKEEP propagation
*   post-reset recovery

**Final result:** 32/32 checks passed.

---

## 8. Layer 2 — Interconnect and Packet-Atomic Arbiter

### 8.1 Purpose
Layer 2 is implemented in: `layer2_axis_arbiter.v`

It connects two independent AXI4-Stream masters to a single downstream stream. The central design requirement is packet atomicity. The arbiter does not switch masters on every beat. Once a master begins a packet, it retains ownership until the beat containing TLAST is transferred.

### 8.2 Why Packet Atomicity Is Required
Suppose two masters were allowed to alternate every beat:
```text
Master 0 → Beat 0
Master 0 → Beat 1
Master 1 → Beat 0
Master 0 → Beat 2
Master 1 → Beat 1
```
The downstream packetizer would observe a single stream and would have no knowledge that the beats came from different sources. Consequently, bytes belonging to unrelated packets could be combined into the same FLIT. 

The arbiter therefore follows:
```text
Grant Master 0
      |
      +--> Beat 0
      +--> Beat 1
      +--> ...
      +--> TLAST
                  |
                  v
             release grant
```
Only after TLAST is transferred can the other source become the owner.

### 8.3 Arbitration Policy
The arbiter examines the two input TVALID conditions:
*   **Only Master 0 requests:** `grant = Master 0`
*   **Only Master 1 requests:** `grant = Master 1`
*   **Both request:** Round-robin arbitration is applied using the identity of the master served previously. The master that was not served last is preferred. This avoids repeatedly favoring one source when both are continuously active.

### 8.4 Locking Mechanism
The arbitration state contains: `locked`, `grant`, `last_served`.
When the first beat of a packet is transferred, the selected master becomes locked. The lock remains active until a transferred beat has `TLAST = 1`. 

At packet completion, `locked = 0`, and the identity of the previously served master is updated for the next arbitration decision.

### 8.5 Contention Example
Suppose both masters have packets available. Initially: `last_served = Master 1`

Then Master 0 is selected. If Master 0 sends:
```text
M0_B0
M0_B1
M0_B2
M0_TLAST
```
Master 1 remains blocked during the entire packet. After `M0_TLAST`, the arbiter becomes eligible to select Master 1. If both masters continue requesting traffic, the round-robin state prevents Master 0 from continuously reacquiring the channel.

### 8.6 Verification
The Layer-2 verification environment includes:
*   directed arbitration tests (single-source traffic, simultaneous contention)
*   packet-boundary checking
*   grant behavior and backpressure handling
*   reset behavior
*   packet-atomicity invariant monitoring
*   source-attribution scoreboard

The packet-atomicity monitor checks that the selected master does not change before TLAST.

**Final result:** 33/33 checks passed, with 0 atomicity violations.

---

## 9. Layer 3 — Link-Layer FLIT Packetizer and CRC

### 9.1 Purpose
Layer 3 is implemented in: `layer3_flit_packetizer.v`

Its function is to convert the 512-bit AXI4-Stream data into fixed-size 256-byte FLITs and append a CRC-32 value. This creates the link-layer representation consumed by Layer 4.

### 9.2 FLIT Formation
Each incoming AXI beat contains 64 bytes.
```text
Beat 0 → 64 bytes
Beat 1 → 64 bytes
Beat 2 → 64 bytes
Beat 3 → 64 bytes
-----------------
Total  = 256 bytes
```
These four beats are stored in a 2048-bit FLIT buffer. After the fourth beat, the complete FLIT is presented downstream.

### 9.3 Packetizer State Machine
The packetizer contains two principal operating states:
*   **ACCUM:** The module accepts input beats and stores them at the corresponding word position in the FLIT buffer. The position is tracked by a beat index.
*   **PRESENT:** Once a complete FLIT is formed, or TLAST causes an early termination, the completed FLIT is held valid until the downstream interface accepts it. The state machine therefore provides controlled transfer across the packetizer-to-PHY boundary.

### 9.4 TKEEP Handling
TKEEP identifies which bytes in an AXI beat are valid. For each byte:
*   `TKEEP bit = 1` → preserve the corresponding byte
*   `TKEEP bit = 0` → write zero in the corresponding FLIT byte

The bytes are not compacted or shifted. This is important for the final partial beat of a packet. For example:
```text
Valid bytes:   [ D0 D1 D2 D3 ... ]
Invalid bytes: [ 00 00 00 ... ]
```
The invalid locations remain in their original byte positions.

### 9.5 Partial FLIT Handling
A packet does not necessarily end exactly after four AXI beats (e.g., Beat 0 → Beat 1 → TLAST). The packetizer must not wait indefinitely for two more beats. Instead, the packetizer:
*   accepts the early TLAST
*   treats the accumulated data as a completed partial FLIT
*   zero-pads unused bytes
*   generates CRC-32
*   marks the result as partial using the corresponding status indication
*   presents the result downstream

This allows short packets to pass through correctly.

### 9.6 CRC-32
The implemented CRC uses the IEEE 802.3 polynomial: `0x04C11DB7`. The CRC computation processes the valid FLIT contents byte-by-byte using the implemented CRC update function. 

The current Stage-1 implementation uses an unrolled combinational computation for the complete FLIT. This provides straightforward functional verification but creates a substantial amount of combinational logic. For a future implementation-oriented revision, the CRC datapath could be pipelined or implemented using a byte-parallel/table-based architecture.

### 9.7 Verification
Layer 3 verification covers:
*   complete four-beat FLIT formation
*   packet termination before four beats
*   TKEEP masking and zero-padding
*   CRC correctness
*   output handshake behavior and reset behavior
*   multiple FLIT sequences

**Final result:** 29/29 checks passed.

---

## 10. Layer 4 — PCIe Protocol-to-PHY Digital Interface

### 10.1 Purpose
Layer 4 is implemented in: `layer4_flit_to_phy_lanes.v`

It converts the 2080-bit FLIT-plus-CRC representation into a digital multi-lane symbol representation. The stage implements:
*   two-bit symbol extraction
*   round-robin lane striping
*   2-bit Gray coding

The module terminates at the digital boundary to a multi-lane SerDes.

### 10.2 Symbol Conversion
The input contains `2080 bits`. Each PAM4 symbol represents two bits.  
Therefore: `2080 / 2 = 1040 symbols`

### 10.3 Lane Striping
The symbol index determines the output lane: `Lane = symbol_index mod 4`

Thus:
```text
Symbol 0 → Lane 0
Symbol 1 → Lane 1
Symbol 2 → Lane 2
Symbol 3 → Lane 3
Symbol 4 → Lane 0
Symbol 5 → Lane 1
...
```
The position within a lane increases every four symbols. Because there are 1040 symbols (`1040 / 4 = 260`), each lane receives exactly 260 symbols.

### 10.4 Gray Coding
Each raw two-bit symbol is mapped using:

| Raw Symbol | Gray-Coded Symbol |
| :---: | :---: |
| 00 | 00 |
| 01 | 01 |
| 10 | 11 |
| 11 | 10 |

This mapping places adjacent logical levels at one-bit Hamming distance, which is desirable for PAM4 signaling. The implementation therefore produces the digital symbol codes that a PHY/SerDes block could consume.

### 10.5 Parameter Consistency
The implementation includes an elaboration-time check to ensure that the total symbol count divides evenly across the configured lane count. This prevents an incompatible combination of FLIT width and lane count from silently producing an incomplete lane distribution.

### 10.6 Scope Boundary
This layer does not generate physical analog PAM4 voltages. The following functions remain outside this RTL scope:
*   analog voltage generation
*   serializer/deserializer circuitry
*   electrical signaling
*   clock/data recovery
*   physical channel behavior

The output of Layer 4 is therefore considered the digital protocol-to-PHY boundary.

### 10.7 Verification
Layer 4 verification covers:
*   symbol extraction
*   lane distribution
*   Gray-code mapping
*   deterministic test patterns
*   output handshaking
*   reset handling
*   multiple input FLITs

**Final result:** 39/39 checks passed.

---

## 11. End-to-End Integration

### 11.1 Integrated Top-Level Design
All four modules are integrated in: `top_4layer_true_split.v`

The complete path is:
```text
Master 0 ──┐
           ├─> Layer 2
Master 1 ──┘
              ↓
           Layer 1
              ↓
           Layer 3
              ↓
           Layer 4
              ↓
        Lane 0..Lane 3
```
The integration environment drives independent traffic patterns from both sources.

### 11.2 Example: Four-Beat Master-0 Packet
Consider one complete packet from Master 0: `M0 Beat 0 → M0 Beat 1 → M0 Beat 2 → M0 Beat 3 / TLAST`

*   **Step 1 — Arbitration:** Layer 2 sees Master 0 requesting the channel and grants it. Because the packet is now in progress, Master 1 cannot take ownership before TLAST.
*   **Step 2 — Register Slice:** Layer 1 accepts the beats and buffers them between Layer 2 and Layer 3.
*   **Step 3 — FLIT Formation:** Layer 3 collects `4 × 512 bits = 2048 bits = 256 bytes`. The FLIT CRC is generated. The result becomes `2048-bit data + 32-bit CRC = 2080 bits`.
*   **Step 4 — Lane Mapping:** Layer 4 converts the 2080-bit stream to `1040 symbols` and distributes them (`260 symbols` per Lane 0-3). Each symbol is Gray-coded before being assigned to its lane.

---

## 12. Multi-Master Contention

A more demanding integrated case is when both masters continuously generate packets.
```text
Master 0:  M0_P0 → M0_P1 → M0_P2 ...
Master 1:  M1_P0 → M1_P1 → ...
```
Layer 2 maintains packet atomicity:
```text
M0 packet
   ↓
TLAST
   ↓
M1 packet
   ↓
TLAST
```
The arbiter therefore prevents packet-level interleaving while round-robin state provides fairness during contention. The integrated testbench records the actual FLIT stream and checks the downstream data, CRC, and lane outputs against the expected result.

---

## 13. Backpressure and Robustness

Backpressure is propagated through the ready/valid interfaces. The key principle is:
```text
Downstream unavailable
        ↓
Layer 4 stalls
        ↓
Layer 3 holds its output
        ↓
Layer 1 holds its buffered beat
        ↓
Upstream ready eventually deasserts
```
The integration verification environment includes an explicit far-end stall scenario to demonstrate that the pipeline does not silently lose or corrupt data while the final output is unavailable. The test also confirms that the pipeline resumes correctly after the stall is released.

---

## 14. Verification Methodology

The verification environment uses a combination of directed tests, structural checking, invariant monitoring, scoreboards, and end-to-end comparison.

### 14.1 Directed Testing
Directed tests are used for deterministic corner cases such as: reset, empty/idle conditions, backpressure, packet boundaries, partial FLITs, known data patterns, and lane mapping patterns.

### 14.2 Atomicity Invariant
The Layer-2 testbench continuously monitors packet ownership. The invariant is:
*Once a master begins a packet, the selected master must remain unchanged until the packet's TLAST transfer completes.*
The final verification result reports: `Atomicity violations = 0`

### 14.3 Scoreboarding
The enhanced verification environment associates identifiable data patterns with the two input masters. The received data is checked against the expected source sequence. This verifies not only that the number of transfers is correct, but also that the actual data originates from the correct master and maintains source ordering.

### 14.4 Independent CRC Checking
The Layer-3 verification includes an independent CRC reference model rather than simply comparing the DUT against an output generated using the same internal procedure. This reduces the chance of reproducing the same implementation error in both the design and the checker.

### 14.5 Integrated Verification
The integrated testbench verifies multi-master traffic, arbitration behavior, FLIT formation, CRC integrity, lane striping, Gray coding, backpressure, and end-to-end data consistency. The final integrated regression passes all checks.

---

## 15. Verification Results

The final verification summary is:

| Block | Verification Checks | Result |
| :--- | :--- | :--- |
| **Layer 1 — AXI4-Stream Ingress** | 32 | All passed |
| **Layer 2 — Arbiter** | 33 | All passed |
| **Layer 2 — Atomicity Monitor** | 0 violations | Passed |
| **Layer 3 — FLIT + CRC** | 29 | All passed |
| **Layer 4 — Lane Striping + Gray/PAM4** | 39 | All passed |
| **Full Integration** | 29 | All passed |
| **Total** | **162 checks** | **162/162 passed** |

The complete simulation outputs and VCD files are included in the project `results/` directory. The project can be reproduced using the supplied Makefile.

---

## 16. Simulation and Reproducibility

The project is organized so that the major verification results can be reproduced using Icarus Verilog. The standard regression command is:
```bash
make all
```
The generated simulation results include compilation output, testbench output, pass/fail summaries, and VCD waveform files. The result files are retained in the project package so that the documented verification claims are supported by simulation evidence.

---

## 17. Synthesis and Implementation Observations

A preliminary Yosys-based structural sanity check was performed. Layer 1 and Layer 2 completed clean structural analysis without inferred latches or reported structural problems.

Layers 3 and 4 contain substantially larger combinational structures:
*   Layer 3 performs the CRC computation across a complete 256-byte FLIT.
*   Layer 4 performs lane/symbol mapping across all 1040 symbols.

As a result, the preliminary synthesis exploration for these layers did not complete within the allotted tool-execution budget. This behavior is consistent with the architecture of the current Stage-1 RTL. For a physical implementation target, these structures should be reconsidered using pipelining, staged CRC computation, and appropriately partitioned symbol-processing logic. These observations are considered optimization targets for a future implementation stage rather than functional failures of the Stage-1 RTL.

---

## 18. Design Trade-Offs

### 18.1 Two Masters Instead of a General N-Way Crossbar
The implementation uses two masters to keep the arbitration mechanism simple enough to verify rigorously, while still demonstrating contention, fairness, packet atomicity, and ownership locking. The mechanism can be generalized in a later stage.

### 18.2 One-Beat Register Slice
Only one register stage is used at the AXI ingress. This minimizes buffering cost while still breaking the combinational path between arbitration and packetization. A deeper FIFO-based architecture could be introduced if additional elasticity is required.

### 18.3 Combinational CRC
The current design favors straightforward functional correctness and direct FLIT processing. The trade-off is increased combinational complexity. A future implementation can pipeline the CRC engine or use a byte-parallel/table-driven approach.

### 18.4 Digital PHY Boundary
The design intentionally terminates at digital lane symbols rather than attempting to model analog PAM4 circuitry. This keeps the RTL aligned with the protocol-to-PHY boundary shown in the challenge reference architecture.

---

## 19. Limitations

The following functions are intentionally outside the current Stage-1 scope:
*   **Full PCIe Controller:** No transaction layer, data-link protocol, configuration space, or host-controller behavior.
*   **Forward Error Correction:** CRC-32 is implemented; a full PCIe-class FEC is out of scope.
*   **Generalized N-Master Crossbar:** The current interconnect supports two masters.
*   **Physical SerDes:** Serialization, electrical signaling, receiver recovery, and analog PAM4 level generation are outside the RTL.
*   **Physical Design:** Complete synthesis optimization, place-and-route, and GDSII generation are reserved for later stages.

---

## 20. Future Work

A future implementation stage can extend the design in several directions:
*   Generalized N-master crossbar and more advanced routing
*   Deeper buffering and improved throughput elasticity
*   Pipelined CRC/FEC logic
*   Complete link-layer transaction management
*   Full PCIe protocol implementation
*   Physical SerDes integration
*   FPGA validation
*   OpenROAD/OpenLane-based implementation
*   Area, timing, power, and reliability optimization
*   Final GDSII generation

---

## 21. Conclusion

This project implements a complete, modular and functionally verified digital datapath covering the principal mechanisms represented by the four layers of the SARCathon 2026 reference architecture.

Two independent AXI4-Stream sources are arbitrated through a packet-atomic round-robin interconnect. The selected data stream is buffered using an AXI4-Stream register slice, converted into fixed 256-byte FLITs with CRC-32 protection, and transformed into four lanes of Gray-coded 2-bit symbols representing the digital interface to a PAM4-oriented SerDes.

The design was verified at both module and integrated levels. The final verification environment reports:
*   **162 / 162 checks passed**
*   **0 packet-atomicity violations**

The project therefore demonstrates a complete Stage-1 RTL implementation with evidence-based functional verification, while clearly defining the boundary between the implemented digital architecture and functionality reserved for future implementation stages.

---

## 22. Project File Structure

```text
project_root/
│
├── rtl/
│   ├── layer1_axis_stream_ingress.v
│   ├── layer2_axis_arbiter.v
│   ├── layer3_flit_packetizer.v
│   ├── layer4_flit_to_phy_lanes.v
│   └── top_4layer_true_split.v
│
├── tb/
│   ├── tb_layer1_axis_stream_ingress.v
│   ├── tb_layer2_axis_arbiter.v
│   ├── tb_layer3_flit_packetizer.v
│   ├── tb_layer4_flit_to_phy_lanes.v
│   └── tb_top_4layer_true_split.v
│
├── sim/
│
├── results/
│   ├── simulation logs
│   └── VCD waveforms
│
├── synthesis/
│   └── synthesis/lint analysis
│
├── physical_design/
│   └── implementation notes
│
├── reports/
│   └── design_document.md
│
├── Makefile
└── README.md
```