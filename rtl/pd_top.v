// =============================================================
// pd_top.v - physical-design wrapper.
// Identical to top_4layer_true_split but WITHOUT the debug counter
// outputs (dbg_*), which saves 64 pins and 64 flip-flops after Yosys
// removes the unused counters.  Functional behaviour is unchanged.
// =============================================================
module pd_top (
    input              clk,
    input              rst_n,

    input  [511:0]     s_axis0_tdata,
    input  [63:0]      s_axis0_tkeep,
    input              s_axis0_tvalid,
    output             s_axis0_tready,
    input              s_axis0_tlast,

    input  [511:0]     s_axis1_tdata,
    input  [63:0]      s_axis1_tkeep,
    input              s_axis1_tvalid,
    output             s_axis1_tready,
    input              s_axis1_tlast,

    output [519:0]     m_lane0_data,
    output [519:0]     m_lane1_data,
    output [519:0]     m_lane2_data,
    output [519:0]     m_lane3_data,
    output             m_lane_valid,
    input              m_lane_ready
);
    top_4layer_true_split u_core (
        .clk(clk), .rst_n(rst_n),
        .s_axis0_tdata(s_axis0_tdata), .s_axis0_tkeep(s_axis0_tkeep),
        .s_axis0_tvalid(s_axis0_tvalid), .s_axis0_tready(s_axis0_tready), .s_axis0_tlast(s_axis0_tlast),
        .s_axis1_tdata(s_axis1_tdata), .s_axis1_tkeep(s_axis1_tkeep),
        .s_axis1_tvalid(s_axis1_tvalid), .s_axis1_tready(s_axis1_tready), .s_axis1_tlast(s_axis1_tlast),
        .m_lane0_data(m_lane0_data), .m_lane1_data(m_lane1_data),
        .m_lane2_data(m_lane2_data), .m_lane3_data(m_lane3_data),
        .m_lane_valid(m_lane_valid), .m_lane_ready(m_lane_ready),
        .dbg_flit_partial(), .dbg_grant0_count(), .dbg_grant1_count()
    );
endmodule
