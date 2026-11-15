// Integrated bidirectional digital-link prototype for SARCathon Stage 2.
//
// TX: two AXI4-Stream sources -> packet-atomic arbiter -> registered ingress
//     -> 256-byte FLIT packetizer + data CRC -> framed four-lane TX mapper.
// RX: incoming four-lane framed data -> inverse Gray/de-stripe -> metadata CRC
//     -> data CRC -> exact 512-bit AXI-Stream beat reconstruction.
//
// The TX and RX lane bundles represent a synchronous digital PHY interface.
// This is not a PCIe 6.0 SerDes, complete PCIe FLIT/FEC implementation, nor
// a memory-mapped AXI4 read/write bridge. Packet TKEEP/TLAST are preserved by
// explicit, CRC-protected framing metadata in this prototype.
module top_4layer_bidir #(
    parameter TDATA_WIDTH = 512,
    parameter FLIT_BYTES  = 256,
    parameter NUM_LANES   = 4,
    parameter SYM_BITS    = 2
)(
    input                         clk,
    input                         rst_n,

    input  [TDATA_WIDTH-1:0]      s_axis0_tdata,
    input  [(TDATA_WIDTH/8)-1:0]  s_axis0_tkeep,
    input                         s_axis0_tvalid,
    output                        s_axis0_tready,
    input                         s_axis0_tlast,

    input  [TDATA_WIDTH-1:0]      s_axis1_tdata,
    input  [(TDATA_WIDTH/8)-1:0]  s_axis1_tkeep,
    input                         s_axis1_tvalid,
    output                        s_axis1_tready,
    input                         s_axis1_tlast,

    output [595:0]                m_tx_lane0_data,
    output [595:0]                m_tx_lane1_data,
    output [595:0]                m_tx_lane2_data,
    output [595:0]                m_tx_lane3_data,
    output                        m_tx_lane_valid,
    input                         m_tx_lane_ready,

    input  [595:0]                s_rx_lane0_data,
    input  [595:0]                s_rx_lane1_data,
    input  [595:0]                s_rx_lane2_data,
    input  [595:0]                s_rx_lane3_data,
    input                         s_rx_lane_valid,
    output                        s_rx_lane_ready,

    output [TDATA_WIDTH-1:0]      m_axis_tdata,
    output [(TDATA_WIDTH/8)-1:0]  m_axis_tkeep,
    output                        m_axis_tvalid,
    input                         m_axis_tready,
    output                        m_axis_tlast,

    output                        rx_error,
    output [1:0]                  rx_error_code,
    output [31:0]                 rx_good_frames,
    output [31:0]                 rx_bad_frames
);
    initial begin
        if (TDATA_WIDTH != 512 || FLIT_BYTES != 256 || NUM_LANES != 4 || SYM_BITS != 2)
            $fatal(1, "top_4layer_bidir currently supports 512-bit AXIS, 256-byte FLITs, 4 lanes, 2-bit symbols");
    end

    // Layer 2: packet-atomic round-robin arbitration of two source streams.
    wire [511:0] arb_tdata;
    wire [63:0]  arb_tkeep;
    wire         arb_tvalid, arb_tready, arb_tlast;
    wire [31:0]  unused_grant0_count, unused_grant1_count;

    layer2_axis_arbiter #(.TDATA_WIDTH(512)) u_layer2 (
        .clk(clk), .rst_n(rst_n),
        .s_axis0_tdata(s_axis0_tdata), .s_axis0_tkeep(s_axis0_tkeep),
        .s_axis0_tvalid(s_axis0_tvalid), .s_axis0_tready(s_axis0_tready), .s_axis0_tlast(s_axis0_tlast),
        .s_axis1_tdata(s_axis1_tdata), .s_axis1_tkeep(s_axis1_tkeep),
        .s_axis1_tvalid(s_axis1_tvalid), .s_axis1_tready(s_axis1_tready), .s_axis1_tlast(s_axis1_tlast),
        .m_axis_tdata(arb_tdata), .m_axis_tkeep(arb_tkeep),
        .m_axis_tvalid(arb_tvalid), .m_axis_tready(arb_tready), .m_axis_tlast(arb_tlast),
        .dbg_grant0_count(unused_grant0_count), .dbg_grant1_count(unused_grant1_count)
    );

    // Layer 1: registered AXI-Stream ingress slice.
    wire [511:0] ing_tdata;
    wire [63:0]  ing_tkeep;
    wire         ing_tvalid, ing_tready, ing_tlast;
    layer1_axis_stream_ingress #(.TDATA_WIDTH(512)) u_layer1 (
        .clk(clk), .rst_n(rst_n),
        .s_tdata(arb_tdata), .s_tkeep(arb_tkeep), .s_tvalid(arb_tvalid),
        .s_tready(arb_tready), .s_tlast(arb_tlast),
        .m_tdata(ing_tdata), .m_tkeep(ing_tkeep), .m_tvalid(ing_tvalid),
        .m_tready(ing_tready), .m_tlast(ing_tlast)
    );

    // Layer 3: data FLIT/CRC plus sideband needed to reconstruct AXIS framing.
    wire [2047:0] flit_data;
    wire [31:0] flit_crc;
    wire [255:0] flit_keep;
    wire [3:0] flit_lasts, flit_beat_valid;
    wire flit_valid, flit_ready, flit_partial;
    layer3_flit_packetizer #(.TDATA_WIDTH(512), .FLIT_BYTES(256)) u_layer3 (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(ing_tdata), .s_axis_tkeep(ing_tkeep),
        .s_axis_tvalid(ing_tvalid), .s_axis_tready(ing_tready), .s_axis_tlast(ing_tlast),
        .m_flit_data(flit_data), .m_flit_crc(flit_crc), .m_flit_valid(flit_valid),
        .m_flit_ready(flit_ready), .m_flit_partial(flit_partial),
        .m_flit_tkeep(flit_keep), .m_flit_tlasts(flit_lasts), .m_flit_beat_valid(flit_beat_valid)
    );

    // TX half: frame and encode all data/metadata into four 596-bit lane words.
    layer4_flit_to_phy_lanes_framed u_tx_lane (
        .clk(clk), .rst_n(rst_n),
        .s_flit_data(flit_data), .s_flit_crc(flit_crc),
        .s_flit_tkeep(flit_keep), .s_flit_tlasts(flit_lasts),
        .s_flit_beat_valid(flit_beat_valid), .s_flit_valid(flit_valid), .s_flit_ready(flit_ready),
        .m_lane0_data(m_tx_lane0_data), .m_lane1_data(m_tx_lane1_data),
        .m_lane2_data(m_tx_lane2_data), .m_lane3_data(m_tx_lane3_data),
        .m_lane_valid(m_tx_lane_valid), .m_lane_ready(m_tx_lane_ready)
    );

    // RX half: each received frame is checked before any beat is released.
    layer4_phy_lanes_to_axis u_rx_lane (
        .clk(clk), .rst_n(rst_n),
        .s_lane0_data(s_rx_lane0_data), .s_lane1_data(s_rx_lane1_data),
        .s_lane2_data(s_rx_lane2_data), .s_lane3_data(s_rx_lane3_data),
        .s_lane_valid(s_rx_lane_valid), .s_lane_ready(s_rx_lane_ready),
        .m_axis_tdata(m_axis_tdata), .m_axis_tkeep(m_axis_tkeep),
        .m_axis_tvalid(m_axis_tvalid), .m_axis_tready(m_axis_tready), .m_axis_tlast(m_axis_tlast),
        .rx_error(rx_error), .rx_error_code(rx_error_code),
        .rx_good_frames(rx_good_frames), .rx_bad_frames(rx_bad_frames)
    );
endmodule
