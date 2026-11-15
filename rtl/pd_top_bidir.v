// Physical-design wrapper for the new bidirectional digital-link prototype.
// The original pd_top (TX-only baseline) is intentionally retained unchanged.
module pd_top_bidir (
    input clk,
    input rst_n,
    input [511:0] s_axis0_tdata,
    input [63:0] s_axis0_tkeep,
    input s_axis0_tvalid,
    output s_axis0_tready,
    input s_axis0_tlast,
    input [511:0] s_axis1_tdata,
    input [63:0] s_axis1_tkeep,
    input s_axis1_tvalid,
    output s_axis1_tready,
    input s_axis1_tlast,
    output [595:0] m_tx_lane0_data,
    output [595:0] m_tx_lane1_data,
    output [595:0] m_tx_lane2_data,
    output [595:0] m_tx_lane3_data,
    output m_tx_lane_valid,
    input m_tx_lane_ready,
    input [595:0] s_rx_lane0_data,
    input [595:0] s_rx_lane1_data,
    input [595:0] s_rx_lane2_data,
    input [595:0] s_rx_lane3_data,
    input s_rx_lane_valid,
    output s_rx_lane_ready,
    output [511:0] m_axis_tdata,
    output [63:0] m_axis_tkeep,
    output m_axis_tvalid,
    input m_axis_tready,
    output m_axis_tlast,
    output rx_error,
    output [1:0] rx_error_code
);
    wire [31:0] unused_good_frames, unused_bad_frames;
    top_4layer_bidir u_core (
        .clk(clk), .rst_n(rst_n),
        .s_axis0_tdata(s_axis0_tdata), .s_axis0_tkeep(s_axis0_tkeep),
        .s_axis0_tvalid(s_axis0_tvalid), .s_axis0_tready(s_axis0_tready), .s_axis0_tlast(s_axis0_tlast),
        .s_axis1_tdata(s_axis1_tdata), .s_axis1_tkeep(s_axis1_tkeep),
        .s_axis1_tvalid(s_axis1_tvalid), .s_axis1_tready(s_axis1_tready), .s_axis1_tlast(s_axis1_tlast),
        .m_tx_lane0_data(m_tx_lane0_data), .m_tx_lane1_data(m_tx_lane1_data),
        .m_tx_lane2_data(m_tx_lane2_data), .m_tx_lane3_data(m_tx_lane3_data),
        .m_tx_lane_valid(m_tx_lane_valid), .m_tx_lane_ready(m_tx_lane_ready),
        .s_rx_lane0_data(s_rx_lane0_data), .s_rx_lane1_data(s_rx_lane1_data),
        .s_rx_lane2_data(s_rx_lane2_data), .s_rx_lane3_data(s_rx_lane3_data),
        .s_rx_lane_valid(s_rx_lane_valid), .s_rx_lane_ready(s_rx_lane_ready),
        .m_axis_tdata(m_axis_tdata), .m_axis_tkeep(m_axis_tkeep),
        .m_axis_tvalid(m_axis_tvalid), .m_axis_tready(m_axis_tready), .m_axis_tlast(m_axis_tlast),
        .rx_error(rx_error), .rx_error_code(rx_error_code),
        .rx_good_frames(unused_good_frames), .rx_bad_frames(unused_bad_frames)
    );
endmodule
