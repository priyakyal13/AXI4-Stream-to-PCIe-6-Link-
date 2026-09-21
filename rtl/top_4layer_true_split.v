// =============================================================
// top_4layer_true_split.v
//
// Full 4-layer datapath with all four spec-named layers as
// genuinely SEPARATE modules (unlike top_4layer_dual_master_legacy.v,
// which uses the fused Layer1+3 module):
//
//   2x AXI4-Stream masters
//     -> [Layer 2: layer2_axis_arbiter]
//     -> [Layer 1: layer1_axis_stream_ingress]
//     -> [Layer 3: layer3_flit_packetizer]
//     -> [Layer 4: layer4_flit_to_phy_lanes]
//     -> 4-lane Gray/PAM4-coded symbol bus
//
// This is the recommended top-level to point to in the technical
// report's architecture table, since it maps one file to each of
// the four rows. top_4layer_dual_master_legacy.v and
// top_3layer_single_master_legacy.v are kept as earlier, already-
// verified milestones, not superseded or deleted.
// =============================================================

module top_4layer_true_split #(
    parameter TDATA_WIDTH = 512,
    parameter FLIT_BYTES  = 256,
    parameter NUM_LANES   = 4,
    parameter SYM_BITS    = 2
)(
    input                               clk,
    input                               rst_n,

    // ---------------- AXI4-Stream Master 0 (system ingress) ----------------
    input      [TDATA_WIDTH-1:0]        s_axis0_tdata,
    input      [(TDATA_WIDTH/8)-1:0]    s_axis0_tkeep,
    input                               s_axis0_tvalid,
    output                              s_axis0_tready,
    input                               s_axis0_tlast,

    // ---------------- AXI4-Stream Master 1 (system ingress) ----------------
    input      [TDATA_WIDTH-1:0]        s_axis1_tdata,
    input      [(TDATA_WIDTH/8)-1:0]    s_axis1_tkeep,
    input                               s_axis1_tvalid,
    output                              s_axis1_tready,
    input                               s_axis1_tlast,

    // ---------------- Lane-striped symbol output (to SerDes) ----------------
    output     [((FLIT_BYTES*8+32)/NUM_LANES)-1:0] m_lane0_data,
    output     [((FLIT_BYTES*8+32)/NUM_LANES)-1:0] m_lane1_data,
    output     [((FLIT_BYTES*8+32)/NUM_LANES)-1:0] m_lane2_data,
    output     [((FLIT_BYTES*8+32)/NUM_LANES)-1:0] m_lane3_data,
    output                              m_lane_valid,
    input                               m_lane_ready,

    // ---------------- debug/visibility (not required downstream) ----------------
    output                              dbg_flit_partial,
    output     [31:0]                   dbg_grant0_count,
    output     [31:0]                   dbg_grant1_count
);

    // -------- Layer 2 output = Layer 1 input --------
    wire [TDATA_WIDTH-1:0]     arb_tdata;
    wire [(TDATA_WIDTH/8)-1:0] arb_tkeep;
    wire                        arb_tvalid;
    wire                        arb_tready;
    wire                        arb_tlast;

    layer2_axis_arbiter #(
        .TDATA_WIDTH(TDATA_WIDTH)
    ) u_layer2 (
        .clk(clk), .rst_n(rst_n),
        .s_axis0_tdata(s_axis0_tdata), .s_axis0_tkeep(s_axis0_tkeep),
        .s_axis0_tvalid(s_axis0_tvalid), .s_axis0_tready(s_axis0_tready), .s_axis0_tlast(s_axis0_tlast),
        .s_axis1_tdata(s_axis1_tdata), .s_axis1_tkeep(s_axis1_tkeep),
        .s_axis1_tvalid(s_axis1_tvalid), .s_axis1_tready(s_axis1_tready), .s_axis1_tlast(s_axis1_tlast),
        .m_axis_tdata(arb_tdata), .m_axis_tkeep(arb_tkeep),
        .m_axis_tvalid(arb_tvalid), .m_axis_tready(arb_tready), .m_axis_tlast(arb_tlast),
        .dbg_grant0_count(dbg_grant0_count), .dbg_grant1_count(dbg_grant1_count)
    );

    // -------- Layer 1 output = Layer 3 input --------
    wire [TDATA_WIDTH-1:0]     ing_tdata;
    wire [(TDATA_WIDTH/8)-1:0] ing_tkeep;
    wire                        ing_tvalid;
    wire                        ing_tready;
    wire                        ing_tlast;

    layer1_axis_stream_ingress #(
        .TDATA_WIDTH(TDATA_WIDTH)
    ) u_layer1 (
        .clk(clk), .rst_n(rst_n),
        .s_tdata(arb_tdata), .s_tkeep(arb_tkeep), .s_tvalid(arb_tvalid), .s_tready(arb_tready), .s_tlast(arb_tlast),
        .m_tdata(ing_tdata), .m_tkeep(ing_tkeep), .m_tvalid(ing_tvalid), .m_tready(ing_tready), .m_tlast(ing_tlast)
    );

    // -------- Layer 3 output = Layer 4 input --------
    wire [FLIT_BYTES*8-1:0] flit_data;
    wire [31:0]              flit_crc;
    wire                      flit_valid;
    wire                      flit_ready;

    layer3_flit_packetizer #(
        .TDATA_WIDTH(TDATA_WIDTH),
        .FLIT_BYTES(FLIT_BYTES)
    ) u_layer3 (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(ing_tdata),
        .s_axis_tkeep(ing_tkeep),
        .s_axis_tvalid(ing_tvalid),
        .s_axis_tready(ing_tready),
        .s_axis_tlast(ing_tlast),
        .m_flit_data(flit_data),
        .m_flit_crc(flit_crc),
        .m_flit_valid(flit_valid),
        .m_flit_ready(flit_ready),
        .m_flit_partial(dbg_flit_partial)
    );

    layer4_flit_to_phy_lanes #(
        .DATA_BITS(FLIT_BYTES*8),
        .CRC_BITS(32),
        .NUM_LANES(NUM_LANES),
        .SYM_BITS(SYM_BITS)
    ) u_layer4 (
        .clk(clk), .rst_n(rst_n),
        .s_flit_data(flit_data),
        .s_flit_crc(flit_crc),
        .s_flit_valid(flit_valid),
        .s_flit_ready(flit_ready),
        .m_lane0_data(m_lane0_data),
        .m_lane1_data(m_lane1_data),
        .m_lane2_data(m_lane2_data),
        .m_lane3_data(m_lane3_data),
        .m_lane_valid(m_lane_valid),
        .m_lane_ready(m_lane_ready)
    );

endmodule
