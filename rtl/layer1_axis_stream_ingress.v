// =============================================================
// layer1_axis_stream_ingress.v
//
// Layer 1 (AXI4-Stream Interface) per the SARCathon reference
// architecture, as its OWN standalone, independently-verifiable
// block — split out from the fused implementation kept at
// legacy_fused_layer1_3_axis_to_flit.v.
//
// This is a standard, fully-registered AXI4-Stream register slice
// ("skid buffer" without the skid path — a single buffered stage):
//   - Breaks any combinational path between the upstream driver
//     and whatever consumes m_t* (here, Layer 3's FLIT packetizer),
//     which is the actual "ingress" job Layer 1 is named for in the
//     spec's function table: buffering/presenting transaction data
//     at the system boundary.
//   - s_tready = m_tready | !m_tvalid: the slave side can always
//     accept a new beat unless the internal register is both full
//     AND the consumer isn't draining it this cycle. This gives
//     full back-to-back throughput (a new beat can be accepted
//     every cycle when the consumer keeps up) at the cost of
//     exactly 1 cycle of added latency per beat — the standard,
//     well-understood trade-off for this pattern.
//   - TKEEP/TLAST are carried through unchanged; this layer does
//     not interpret packet boundaries, only forwards them (that's
//     Layer 3's job).
// =============================================================

module layer1_axis_stream_ingress #(
    parameter TDATA_WIDTH = 512
)(
    input                              clk,
    input                              rst_n,

    // ---------------- AXI4-Stream Slave (system ingress) ----------------
    input      [TDATA_WIDTH-1:0]       s_tdata,
    input      [(TDATA_WIDTH/8)-1:0]   s_tkeep,
    input                              s_tvalid,
    output                             s_tready,
    input                              s_tlast,

    // ---------------- AXI4-Stream Master (to Layer 3) ----------------
    output reg [TDATA_WIDTH-1:0]       m_tdata,
    output reg [(TDATA_WIDTH/8)-1:0]   m_tkeep,
    output reg                         m_tvalid,
    input                              m_tready,
    output reg                         m_tlast
);

    assign s_tready = m_tready || !m_tvalid;

    // v7 (timing/area): only the valid bit is reset.  m_tdata/m_tkeep/m_tlast are
    // sideband data that no consumer reads while m_tvalid = 0, so they need no reset
    // (removes ~577 reset loads from the rst_n net).
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)          m_tvalid <= 1'b0;
        else if (s_tready)   m_tvalid <= s_tvalid;
    end

    always @(posedge clk) begin
        if (s_tready && s_tvalid) begin
            m_tdata <= s_tdata;
            m_tkeep <= s_tkeep;
            m_tlast <= s_tlast;
        end
        // if !s_tready: buffer is full and consumer isn't draining
        // this cycle -> hold everything (no assignment => retains).
    end

endmodule
