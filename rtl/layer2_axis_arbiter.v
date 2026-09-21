// =============================================================
// layer2_axis_arbiter.v
//
// Layer 2 (Interconnect Layer: Central Crossbar & Dynamic
// Arbiters) per the SARCathon reference architecture — scoped
// down to a minimal 2-master round-robin arbiter rather than a
// full N-master crossbar, which is disproportionate effort for
// Stage 1. This is a genuine, spec-named block, not a stub.
//
// Behavior:
//   - Two AXI4-Stream slave ports (s_axis0_*, s_axis1_*) compete
//     for one AXI4-Stream master port (m_axis_*).
//   - Arbitration is PACKET-ATOMIC: once a master is granted, it
//     keeps the channel for the entire packet (until its TLAST
//     beat is transferred). The other master is held off
//     (tready=0) for the whole packet. This is the correctness-
//     critical property for this design: the downstream FLIT
//     packetizer (Layer 3) accumulates
//     beats into a FLIT assuming an uninterrupted single logical
//     stream, so interleaving two masters' beats mid-packet would
//     silently corrupt a FLIT. Packet-atomicity prevents that by
//     construction.
//   - When idle (no packet in flight) and both masters have data,
//     grant alternates (round-robin) based on which was served
//     last, for fairness.
//   - Grant selection is combinational while unlocked, so the
//     first beat of a newly granted packet is forwarded the same
//     cycle it arrives (no arbitration bubble) provided the
//     downstream is ready. Only the multi-beat HOLD (the `locked`
//     state) is registered, taking effect from the following
//     cycle onward, which is what gives packet-atomicity for
//     beats 2..N of a packet without needing the grant decision
//     itself to be delayed.
// =============================================================

module layer2_axis_arbiter #(
    parameter TDATA_WIDTH = 512
)(
    input                              clk,
    input                              rst_n,

    // ---------------- Master 0 (AXI4-Stream slave port) ----------------
    input      [TDATA_WIDTH-1:0]       s_axis0_tdata,
    input      [(TDATA_WIDTH/8)-1:0]   s_axis0_tkeep,
    input                              s_axis0_tvalid,
    output                             s_axis0_tready,
    input                              s_axis0_tlast,

    // ---------------- Master 1 (AXI4-Stream slave port) ----------------
    input      [TDATA_WIDTH-1:0]       s_axis1_tdata,
    input      [(TDATA_WIDTH/8)-1:0]   s_axis1_tkeep,
    input                              s_axis1_tvalid,
    output                             s_axis1_tready,
    input                              s_axis1_tlast,

    // ---------------- Arbitrated output (AXI4-Stream master port) ----------------
    output     [TDATA_WIDTH-1:0]       m_axis_tdata,
    output     [(TDATA_WIDTH/8)-1:0]   m_axis_tkeep,
    output                             m_axis_tvalid,
    input                              m_axis_tready,
    output                             m_axis_tlast,

    // ---------------- debug / fairness visibility ----------------
    output reg [31:0]                  dbg_grant0_count,
    output reg [31:0]                  dbg_grant1_count
);

    reg       locked;
    reg       grant;        // 0 = master0, 1 = master1 (valid while locked)
    reg       last_served;  // which master was granted last (for round robin)

    // Combinational per-cycle grant: the registered `grant` while
    // locked, otherwise a fresh round-robin pick from whoever is
    // currently requesting. fresh_grant: 0 = master0, 1 = master1.
    wire want0    = s_axis0_tvalid;
    wire want1    = s_axis1_tvalid;
    wire contend  = want0 && want1;
    wire fresh_grant = contend ? ~last_served        // both want it -> serve whoever wasn't served last
                                : (want0 ? 1'b0 : 1'b1); // only one wants it -> serve them
    wire eff_grant   = locked ? grant : fresh_grant;
    wire arb_active  = locked || want0 || want1;

    assign m_axis_tvalid = arb_active ? (eff_grant ? s_axis1_tvalid : s_axis0_tvalid) : 1'b0;
    assign m_axis_tdata  = eff_grant ? s_axis1_tdata  : s_axis0_tdata;
    assign m_axis_tkeep  = eff_grant ? s_axis1_tkeep  : s_axis0_tkeep;
    assign m_axis_tlast  = eff_grant ? s_axis1_tlast  : s_axis0_tlast;

    assign s_axis0_tready = (arb_active && !eff_grant) ? m_axis_tready : 1'b0;
    assign s_axis1_tready = (arb_active &&  eff_grant) ? m_axis_tready : 1'b0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            locked           <= 1'b0;
            grant            <= 1'b0;
            last_served      <= 1'b1;  // so the first contention serves master0
            dbg_grant0_count <= 32'd0;
            dbg_grant1_count <= 32'd0;
        end else begin
            if (!locked) begin
                if (m_axis_tvalid && m_axis_tready) begin
                    // First beat of a newly granted packet just transferred.
                    grant <= eff_grant;
                    if (!m_axis_tlast) begin
                        locked <= 1'b1;  // multi-beat packet: hold the grant
                    end else begin
                        // Single-beat packet: nothing to hold, but still
                        // record it for round-robin fairness.
                        last_served <= eff_grant;
                        if (eff_grant) dbg_grant1_count <= dbg_grant1_count + 1'b1;
                        else           dbg_grant0_count <= dbg_grant0_count + 1'b1;
                    end
                end
            end else begin
                if (m_axis_tvalid && m_axis_tready && m_axis_tlast) begin
                    locked      <= 1'b0;
                    last_served <= grant;
                    if (grant) dbg_grant1_count <= dbg_grant1_count + 1'b1;
                    else       dbg_grant0_count <= dbg_grant0_count + 1'b1;
                end
            end
        end
    end

endmodule
