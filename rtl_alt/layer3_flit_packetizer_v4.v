// =============================================================
// layer3_flit_packetizer.v   (Stage 2 rewrite - v2, drop-in)
//
// Same ports / same behaviour as the Stage 1 block, new internals:
//   * CRC is INCREMENTAL: a 32-bit running CRC register is updated once
//     per 512-bit beat through crc32_d512 (GF(2) matrix form).
//     Stage 1 computed CRC over the whole 2048-bit FLIT in one
//     combinational cone (~18k XOR cells, Yosys ~220 s).
//   * Early TLAST: remaining words are filled with zero in a short FLUSH
//     state (0..2 cycles); the same CRC engine is fed zero beats, so the
//     CRC still covers the full zero-padded 256-byte FLIT.
//   * Output is taken straight from the accumulation buffer (no second
//     2048-bit output register) -> ~2048 fewer flip-flops.
//
// v4: FULL THROUGHPUT.  While a FLIT is presented and the consumer takes it
//     this cycle (m_flit_ready), the next beat is accepted in the SAME cycle
//     and written into word 0 (the consumer samples the old value at that
//     edge).  No second buffer needed -> 4 beats/FLIT = 4 cycles/FLIT
//     (v3 needed 5).  If no beat is waiting at hand-off, outputs stay stable.
//
// Requires TDATA_WIDTH = 512 and FLIT_BYTES = 256 (crc32_d512 is 512-bit).
// =============================================================
module layer3_flit_packetizer #(
    parameter TDATA_WIDTH    = 512,
    parameter FLIT_BYTES     = 256,
    parameter WORDS_PER_FLIT = (FLIT_BYTES*8) / TDATA_WIDTH   // = 4
)(
    input                             clk,
    input                             rst_n,

    input      [TDATA_WIDTH-1:0]      s_axis_tdata,
    input      [(TDATA_WIDTH/8)-1:0]  s_axis_tkeep,
    input                             s_axis_tvalid,
    output                            s_axis_tready,
    input                             s_axis_tlast,

    output     [FLIT_BYTES*8-1:0]     m_flit_data,
    output     [31:0]                 m_flit_crc,
    output                            m_flit_valid,
    input                             m_flit_ready,
    output reg                        m_flit_partial
);

    initial begin
        if (TDATA_WIDTH != 512 || WORDS_PER_FLIT != 4)
            $fatal(1, "layer3_flit_packetizer: needs TDATA_WIDTH=512, 4 words/FLIT");
    end

    localparam [1:0] ACCUM = 2'd0, FLUSH = 2'd1, PRESENT = 2'd2;
    localparam [31:0] CRC_INIT = 32'hFFFFFFFF;

    reg [1:0]               state;
    reg [1:0]               word_idx;
    reg [FLIT_BYTES*8-1:0]  flit_buf;
    reg [31:0]              crc_reg;   // holds the finished CRC until the next FLIT's first beat
    reg                     fresh;     // 1 = next beat starts a new CRC (seed = CRC_INIT)

    // TKEEP: bytes not kept are written as 0 (not compacted)
    wire [TDATA_WIDTH-1:0] masked;
    genvar g;
    generate
        for (g = 0; g < TDATA_WIDTH/8; g = g + 1) begin : g_mask
            assign masked[8*g +: 8] = s_axis_tkeep[g] ? s_axis_tdata[8*g +: 8] : 8'h00;
        end
    endgenerate

    // one CRC engine, shared by real beats and zero-padding beats
    wire [511:0] crc_data = (state == FLUSH) ? 512'b0 : masked;
    wire [31:0]  crc_in = (fresh || state == PRESENT) ? CRC_INIT : crc_reg;
    wire [31:0]  crc_next;
    crc32_d512 u_crc (.crc_in(crc_in), .data(crc_data), .crc_out(crc_next));

    assign s_axis_tready = (state == ACCUM) || (state == PRESENT && m_flit_ready);
    wire accept = s_axis_tvalid && s_axis_tready;
    assign m_flit_valid  = (state == PRESENT);
    assign m_flit_data   = flit_buf;
    assign m_flit_crc    = ~crc_reg;           // final XOR

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= ACCUM;
            word_idx       <= 2'd0;
            flit_buf       <= {(FLIT_BYTES*8){1'b0}};
            crc_reg        <= CRC_INIT;
            fresh          <= 1'b1;
            m_flit_partial <= 1'b0;
        end else begin
            if (state == FLUSH) begin
                flit_buf[word_idx*TDATA_WIDTH +: TDATA_WIDTH] <= {TDATA_WIDTH{1'b0}};
                crc_reg <= crc_next;                  // zero beat
                if (word_idx == 2'd3) begin
                    state    <= PRESENT;
                    word_idx <= 2'd0;
                end else
                    word_idx <= word_idx + 2'd1;
            end
            else if (accept) begin
                // state is ACCUM, or PRESENT being handed off (word_idx == 0)
                flit_buf[word_idx*TDATA_WIDTH +: TDATA_WIDTH] <= masked;
                crc_reg <= crc_next;
                fresh   <= 1'b0;
                if (s_axis_tlast) begin
                    m_flit_partial <= (word_idx != 2'd3);
                    if (word_idx == 2'd3) begin
                        state    <= PRESENT;
                        word_idx <= 2'd0;
                    end else begin
                        state    <= FLUSH;
                        word_idx <= word_idx + 2'd1;
                    end
                end else if (word_idx == 2'd3) begin
                    m_flit_partial <= 1'b0;
                    state          <= PRESENT;
                    word_idx       <= 2'd0;
                end else begin
                    state    <= ACCUM;
                    word_idx <= word_idx + 2'd1;
                end
            end
            else if (state == PRESENT && m_flit_ready) begin
                state <= ACCUM;
                fresh <= 1'b1;        // crc_reg/flit_buf stay stable after hand-off
            end
        end
    end
endmodule
