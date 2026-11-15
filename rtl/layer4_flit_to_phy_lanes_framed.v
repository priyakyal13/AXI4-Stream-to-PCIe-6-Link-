// Four-lane, 2-bit-symbol TX mapper for the bidirectional digital link.
//
// Frame layout, least-significant field first:
//   [2047:0]    256-byte data FLIT
//   [2079:2048] CRC-32 of the data FLIT (supplied by Layer 3)
//   [2335:2080] byte TKEEP for the four 512-bit beats (256 bits)
//   [2339:2336] TLAST per beat (4 bits)
//   [2343:2340] valid-beat mask (4 bits; distinguishes padding from a valid zero-keep beat)
//   [2351:2344] magic/version byte 0xA5
//   [2383:2352] CRC-32 of the 272-bit metadata field
//
// Total is 2384 bits = 1192 2-bit symbols = 4 lanes x 298 symbols (596 bits/lane).
// Gray mapping matches the legacy Layer 4 mapper. This is a simplified
// synchronous digital-link representation, not a PCIe 6.0 SerDes implementation.
module layer4_flit_to_phy_lanes_framed (
    input          clk,
    input          rst_n,
    input  [2047:0] s_flit_data,
    input  [31:0]   s_flit_crc,
    input  [255:0]  s_flit_tkeep,
    input  [3:0]    s_flit_tlasts,
    input  [3:0]    s_flit_beat_valid,
    input          s_flit_valid,
    output         s_flit_ready,
    output [595:0]  m_lane0_data,
    output [595:0]  m_lane1_data,
    output [595:0]  m_lane2_data,
    output [595:0]  m_lane3_data,
    output         m_lane_valid,
    input          m_lane_ready
);
    localparam [7:0] MAGIC = 8'hA5;
    reg [2383:0] frame_reg;
    reg frame_valid;

    wire [271:0] meta_fields = {MAGIC, s_flit_beat_valid, s_flit_tlasts, s_flit_tkeep};
    wire [31:0] meta_crc;
    crc32_meta_272 u_meta_crc (.data(meta_fields), .crc(meta_crc));
    wire [2383:0] frame_in = {meta_crc, meta_fields, s_flit_crc, s_flit_data};

    wire [2383:0] lane_flat;
    genvar slot, lane;
    generate
        for (slot = 0; slot < 298; slot = slot + 1) begin : g_slot
            for (lane = 0; lane < 4; lane = lane + 1) begin : g_lane
                wire [1:0] raw_symbol = frame_reg[(slot*4 + lane)*2 +: 2];
                assign lane_flat[lane*596 + slot*2 +: 2] = {raw_symbol[1], raw_symbol[1] ^ raw_symbol[0]};
            end
        end
    endgenerate

    assign m_lane0_data = lane_flat[0*596 +: 596];
    assign m_lane1_data = lane_flat[1*596 +: 596];
    assign m_lane2_data = lane_flat[2*596 +: 596];
    assign m_lane3_data = lane_flat[3*596 +: 596];
    assign s_flit_ready = !frame_valid;
    assign m_lane_valid = frame_valid;

    // v7: only frame_valid is reset.  frame_reg is meaningful only while m_lane_valid = 1
    // (it is fully loaded on the edge that sets frame_valid), so it needs no reset value;
    // this removes 2384 reset loads from rst_n.  Lane data seen while m_lane_valid = 0 is
    // don't-care (it was all-zero after reset in v6 and earlier; now it is unspecified).
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            frame_valid <= 1'b0;
        else if (s_flit_valid && s_flit_ready)
            frame_valid <= 1'b1;
        else if (frame_valid && m_lane_ready)
            frame_valid <= 1'b0;
    end

    always @(posedge clk) begin
        if (s_flit_valid && s_flit_ready)
            frame_reg <= frame_in;
    end
endmodule
