// =============================================================================
// layer4_phy_lanes_to_axis.v   (v6, timing-restructured RX)
//
// RX half of the framed four-lane digital link.  External interface, frame
// format, Gray mapping, lane ordering, CRC conventions and error codes are
// IDENTICAL to the previous revision; only the internal micro-architecture
// changed (latency +1 cycle per frame).
//
// Why it changed (measured, see reports/timing_comparison.md):
//   The old RX decoded the raw lane PORTS, ran the 34-byte metadata CRC
//   (bit-serial loop => ~272-step mux/XOR chain), the magic compare and the
//   buffer load enable ALL in the cycle of acceptance, and then compared the
//   32-bit data CRC directly behind the 512-bit XOR tree.
//
// New structure:
//   IDLE : every cycle the Gray-decoded lane ports are captured into the frame
//          buffers (port -> 1 XOR -> flop; no CRC, no compare, and the enable is
//          a registered state bit rather than the s_lane_valid input).  The
//          frame that is on the ports at the edge where s_lane_valid&&ready is
//          true is therefore the frame that is held, exactly as before.
//   CRC  : 4 cycles, one 512-bit word per cycle through crc32_d512.  In
//          parallel, a free-running 2-stage pipeline checks magic + metadata
//          CRC from the (stable) metadata buffer.
//   FIN  : one cycle; compares REGISTERED 32-bit values only and decides
//          good / bad (priority: bad magic > meta CRC > data CRC, as before).
//   OUT  : unchanged beat release (TKEEP/TLAST/valid-beat handling).
//
// Data-path buffers have no reset: while the FSM is in IDLE (its reset state)
// they are loaded every clock, and nothing reads them unless state != IDLE.
// =============================================================================
module layer4_phy_lanes_to_axis (
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
    localparam [1:0] ST_IDLE = 2'd0, ST_CRC = 2'd1, ST_FIN = 2'd2, ST_OUT = 2'd3;
    localparam [7:0] MAGIC = 8'hA5;

    reg [1:0]  state;
    reg [1:0]  crc_word_idx;
    reg [1:0]  beat_idx;
    reg [31:0] running_crc;

    // ---- frame buffers (no reset; see header) ------------------------------
    reg [2047:0] data_buf;
    reg [31:0]   dcrc_buf;     // CRC-32 carried in the frame (data)
    reg [271:0]  meta_buf;     // TKEEP | TLAST | beat-valid | magic
    reg [31:0]   mcrc_buf;     // CRC-32 carried in the frame (metadata)

    // ---- Gray decode: raw symbol {g1,g0} -> {g1, g1^g0}; frame symbol index = slot*4+lane
    wire [595:0] ln0 = s_lane0_data, ln1 = s_lane1_data, ln2 = s_lane2_data, ln3 = s_lane3_data;
    wire [2383:0] decoded_frame;
    genvar slot;
    generate
        for (slot = 0; slot < 298; slot = slot + 1) begin : g_slot
            wire [1:0] g0 = ln0[slot*2 +: 2];
            wire [1:0] g1 = ln1[slot*2 +: 2];
            wire [1:0] g2 = ln2[slot*2 +: 2];
            wire [1:0] g3 = ln3[slot*2 +: 2];
            assign decoded_frame[(slot*4 + 0)*2 +: 2] = {g0[1], g0[1] ^ g0[0]};
            assign decoded_frame[(slot*4 + 1)*2 +: 2] = {g1[1], g1[1] ^ g1[0]};
            assign decoded_frame[(slot*4 + 2)*2 +: 2] = {g2[1], g2[1] ^ g2[0]};
            assign decoded_frame[(slot*4 + 3)*2 +: 2] = {g3[1], g3[1] ^ g3[0]};
        end
    endgenerate

    wire load = (state == ST_IDLE);
    always @(posedge clk) begin
        if (load) begin
            data_buf <= decoded_frame[0    +: 2048];
            dcrc_buf <= decoded_frame[2048 +: 32];
            meta_buf <= decoded_frame[2080 +: 272];
            mcrc_buf <= decoded_frame[2352 +: 32];
        end
    end

    // ---- metadata check: free-running 2-stage pipeline on the stable meta_buf
    wire [31:0] meta_crc_calc;
    crc32_meta_272 u_meta_crc (.data(meta_buf), .crc(meta_crc_calc));
    reg [31:0] meta_crc_q;       // stage 1: calculated CRC (registered)
    reg        magic_ok_q;       // stage 1: magic/version byte matches
    reg        mcrc_ok_q;        // stage 2: calculated CRC == carried CRC
    reg        magic_ok_qq;
    always @(posedge clk) begin
        meta_crc_q  <= meta_crc_calc;
        magic_ok_q  <= (meta_buf[271:264] == MAGIC);
        mcrc_ok_q   <= (meta_crc_q == mcrc_buf);
        magic_ok_qq <= magic_ok_q;
    end

    // ---- data CRC engine: one 512-bit word per cycle
    wire [511:0] crc_word = data_buf[crc_word_idx*512 +: 512];
    wire [31:0]  crc_next;
    crc32_d512 u_data_crc (.crc_in(running_crc), .data(crc_word), .crc_out(crc_next));

    // ---- AXI-Stream outputs
    assign s_lane_ready  = (state == ST_IDLE);
    assign m_axis_tvalid = (state == ST_OUT) && meta_buf[260 + beat_idx];
    assign m_axis_tdata  = data_buf[beat_idx*512 +: 512];
    assign m_axis_tkeep  = meta_buf[beat_idx*64 +: 64];
    assign m_axis_tlast  = meta_buf[256 + beat_idx];

    wire data_crc_ok = (~running_crc == dcrc_buf);

    // v7: running_crc has no reset; it is re-seeded every cycle while the FSM sits in IDLE
    // (its reset state), so it is always defined before the first CRC cycle.
    always @(posedge clk) begin
        if (state == ST_IDLE)     running_crc <= 32'hFFFFFFFF;
        else if (state == ST_CRC) running_crc <= crc_next;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= ST_IDLE;
            crc_word_idx   <= 2'd0;
            beat_idx       <= 2'd0;
            rx_error       <= 1'b0;
            rx_error_code  <= 2'd0;
            rx_good_frames <= 32'd0;
            rx_bad_frames  <= 32'd0;
        end else begin
            rx_error      <= 1'b0;
            rx_error_code <= 2'd0;

            case (state)
                ST_IDLE: begin
                    crc_word_idx <= 2'd0;
                    if (s_lane_valid) state <= ST_CRC;    // buffers loaded on this edge
                end

                ST_CRC: begin
                    if (crc_word_idx == 2'd3) state <= ST_FIN;
                    else                      crc_word_idx <= crc_word_idx + 2'd1;
                end

                ST_FIN: begin
                    if (magic_ok_qq && mcrc_ok_q && data_crc_ok) begin
                        rx_good_frames <= rx_good_frames + 1'b1;
                        beat_idx       <= 2'd0;
                        state          <= ST_OUT;
                    end else begin
                        rx_error      <= 1'b1;
                        rx_error_code <= !magic_ok_qq ? 2'd3 : (!mcrc_ok_q ? 2'd2 : 2'd1);
                        rx_bad_frames <= rx_bad_frames + 1'b1;
                        state         <= ST_IDLE;
                    end
                end

                ST_OUT: begin
                    if (!meta_buf[260 + beat_idx] || m_axis_tready) begin
                        if (beat_idx == 2'd3) begin
                            state    <= ST_IDLE;
                            beat_idx <= 2'd0;
                        end else begin
                            beat_idx <= beat_idx + 2'd1;
                        end
                    end
                end
            endcase
        end
    end
endmodule
