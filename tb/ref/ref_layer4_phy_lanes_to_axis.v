// REFERENCE: verbatim copy of the original (pre-redesign) RX, only module names suffixed _ref.
// RX half of the framed four-lane digital link.
// Inverse Gray decoding/de-striping, metadata CRC check, data CRC check,
// and AXI4-Stream beat reconstruction. A corrupted FLIT is dropped and
// reported; no bytes from a bad FLIT are exposed downstream.
module layer4_phy_lanes_to_axis_ref (
    input          clk,
    input          rst_n,
    input  [595:0]  s_lane0_data,
    input  [595:0]  s_lane1_data,
    input  [595:0]  s_lane2_data,
    input  [595:0]  s_lane3_data,
    input          s_lane_valid,
    output         s_lane_ready,
    output [511:0]  m_axis_tdata,
    output [63:0]   m_axis_tkeep,
    output         m_axis_tvalid,
    input          m_axis_tready,
    output         m_axis_tlast,
    output reg      rx_error,
    output reg [1:0] rx_error_code,
    output reg [31:0] rx_good_frames,
    output reg [31:0] rx_bad_frames
);
    localparam [1:0] ST_IDLE = 2'd0, ST_CHECK_CRC = 2'd1, ST_OUTPUT = 2'd2;
    localparam [7:0] MAGIC = 8'hA5;

    reg [1:0] state;
    reg [2047:0] data_buf;
    reg [255:0] keep_buf;
    reg [3:0] last_buf;
    reg [3:0] beat_valid_buf;
    reg [31:0] expected_data_crc;
    reg [31:0] running_crc;
    reg [1:0] crc_word_idx;
    reg [1:0] beat_idx;

    wire [2383:0] lane_flat;
    assign lane_flat[0*596 +: 596] = s_lane0_data;
    assign lane_flat[1*596 +: 596] = s_lane1_data;
    assign lane_flat[2*596 +: 596] = s_lane2_data;
    assign lane_flat[3*596 +: 596] = s_lane3_data;

    wire [2383:0] decoded_frame;
    genvar slot, lane;
    generate
        for (slot = 0; slot < 298; slot = slot + 1) begin : g_slot
            for (lane = 0; lane < 4; lane = lane + 1) begin : g_lane
                wire [1:0] gray_symbol = lane_flat[lane*596 + slot*2 +: 2];
                assign decoded_frame[(slot*4 + lane)*2 +: 2] = {gray_symbol[1], gray_symbol[1] ^ gray_symbol[0]};
            end
        end
    endgenerate

    wire [2047:0] decoded_data = decoded_frame[0 +: 2048];
    wire [31:0] decoded_data_crc = decoded_frame[2048 +: 32];
    wire [271:0] decoded_meta = decoded_frame[2080 +: 272];
    wire [31:0] decoded_meta_crc = decoded_frame[2352 +: 32];
    wire [31:0] calculated_meta_crc;
    crc32_meta_272_ref u_meta_crc (.data(decoded_meta), .crc(calculated_meta_crc));

    wire [511:0] crc_word = data_buf[crc_word_idx*512 +: 512];
    wire [31:0] crc_next;
    crc32_d512 u_data_crc (.crc_in(running_crc), .data(crc_word), .crc_out(crc_next));

    assign s_lane_ready = (state == ST_IDLE);
    assign m_axis_tvalid = (state == ST_OUTPUT) && beat_valid_buf[beat_idx];
    assign m_axis_tdata = data_buf[beat_idx*512 +: 512];
    assign m_axis_tkeep = keep_buf[beat_idx*64 +: 64];
    assign m_axis_tlast = last_buf[beat_idx];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= ST_IDLE;
            data_buf        <= 2048'd0;
            keep_buf        <= 256'd0;
            last_buf        <= 4'd0;
            beat_valid_buf  <= 4'd0;
            expected_data_crc <= 32'd0;
            running_crc     <= 32'hFFFFFFFF;
            crc_word_idx    <= 2'd0;
            beat_idx        <= 2'd0;
            rx_error        <= 1'b0;
            rx_error_code   <= 2'd0;
            rx_good_frames  <= 32'd0;
            rx_bad_frames   <= 32'd0;
        end else begin
            rx_error      <= 1'b0;
            rx_error_code <= 2'd0;

            case (state)
                ST_IDLE: begin
                    if (s_lane_valid && s_lane_ready) begin
                        if (decoded_meta[271:264] != MAGIC) begin
                            rx_error      <= 1'b1;
                            rx_error_code <= 2'd3; // bad magic/version
                            rx_bad_frames <= rx_bad_frames + 1'b1;
                        end else if (calculated_meta_crc != decoded_meta_crc) begin
                            rx_error      <= 1'b1;
                            rx_error_code <= 2'd2; // metadata CRC mismatch
                            rx_bad_frames <= rx_bad_frames + 1'b1;
                        end else begin
                            data_buf          <= decoded_data;
                            expected_data_crc <= decoded_data_crc;
                            keep_buf          <= decoded_meta[255:0];
                            last_buf          <= decoded_meta[259:256];
                            beat_valid_buf    <= decoded_meta[263:260];
                            running_crc       <= 32'hFFFFFFFF;
                            crc_word_idx      <= 2'd0;
                            state             <= ST_CHECK_CRC;
                        end
                    end
                end

                ST_CHECK_CRC: begin
                    if (crc_word_idx == 2'd3) begin
                        if ((~crc_next) == expected_data_crc) begin
                            rx_good_frames <= rx_good_frames + 1'b1;
                            beat_idx <= 2'd0;
                            state <= ST_OUTPUT;
                        end else begin
                            rx_error      <= 1'b1;
                            rx_error_code <= 2'd1; // data CRC mismatch
                            rx_bad_frames <= rx_bad_frames + 1'b1;
                            state <= ST_IDLE;
                        end
                    end else begin
                        running_crc  <= crc_next;
                        crc_word_idx <= crc_word_idx + 2'd1;
                    end
                end

                ST_OUTPUT: begin
                    if (!beat_valid_buf[beat_idx]) begin
                        if (beat_idx == 2'd3) begin
                            state <= ST_IDLE;
                            beat_idx <= 2'd0;
                        end else begin
                            beat_idx <= beat_idx + 2'd1;
                        end
                    end else if (m_axis_tready) begin
                        if (beat_idx == 2'd3) begin
                            state <= ST_IDLE;
                            beat_idx <= 2'd0;
                        end else begin
                            beat_idx <= beat_idx + 2'd1;
                        end
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
