// =============================================================
// layer3_flit_packetizer.v   (Stage 2 rewrite - v2, drop-in)
//
// Same ports / same behaviour as the Stage 1 block, new internals:
//   * CRC is INCREMENTAL: a 32-bit running CRC register is updated once
//     per 512-bit beat through crc32_d512 (GF(2) matrix form).
//     Stage 1 computed CRC over the whole 2048-bit FLIT in one
//     combinational cone (~18k XOR cells, Yosys ~220 s).
//   * Early TLAST: remaining words are zero-filled (see v5 note below)
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
// v5: NO FLUSH CYCLES.  On an early TLAST at word w, the remaining (3-w)
//     zero words are written in the SAME cycle and the CRC jumps over the
//     zero padding with one matrix multiply (crc32_zero_skip = A^(3-w)).
//     Short packets now cost 1 cycle per FLIT instead of 4.
//
// v6 (timing): the zero-skip multiply (A^k) is no longer in the CRC accumulate
//     loop.  crc_reg always stores the plain running CRC (un-skipped) and a 2-bit
//     `skip_k` remembers how many zero beats were elided; m_flit_crc applies A^k
//     on the way OUT of the register (crc_reg -> A^k -> output).  crc_reg is never
//     reused as a seed after a partial FLIT (the next FLIT restarts from CRC_INIT),
//     so m_flit_crc is bit-for-bit what it was in v5 whenever m_flit_valid=1, with
//     identical handshake timing.  This removes ~7 logic levels (32x32 GF(2) matrix
//     + 4:1 mux) from the critical 512-bit CRC loop.
//
// v7 (reset fan-out / area): only state, word_idx, fresh and m_flit_partial are reset.
//     flit_buf, sideband buffers, crc_reg and skip_k have no reset (see the datapath
//     block).  Handshake timing and every output value seen while m_flit_valid = 1 are
//     unchanged.
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
    output reg                        m_flit_partial,

    // Framing sideband retained for the bidirectional digital-link variant.
    // One TKEEP bit per payload byte; one TLAST and beat-valid bit per 512-bit beat.
    output     [FLIT_BYTES-1:0]        m_flit_tkeep,
    output     [WORDS_PER_FLIT-1:0]   m_flit_tlasts,
    output     [WORDS_PER_FLIT-1:0]   m_flit_beat_valid
);

    initial begin
        if (TDATA_WIDTH != 512 || WORDS_PER_FLIT != 4)
            $fatal(1, "layer3_flit_packetizer: needs TDATA_WIDTH=512, 4 words/FLIT");
    end

    localparam [1:0] ACCUM = 2'd0, PRESENT = 2'd2;
    localparam [31:0] CRC_INIT = 32'hFFFFFFFF;

    reg [1:0]               state;
    reg [1:0]               word_idx;
    reg [FLIT_BYTES*8-1:0]  flit_buf;
    reg [FLIT_BYTES-1:0]   flit_keep_buf;
    reg [WORDS_PER_FLIT-1:0] flit_tlast_buf;
    reg [WORDS_PER_FLIT-1:0] flit_beat_valid_buf;
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

    // one CRC engine, one beat per clock
    wire [31:0]  crc_in = (fresh || state == PRESENT) ? CRC_INIT : crc_reg;
    wire [31:0]  crc_next;
    crc32_d512 u_crc (.crc_in(crc_in), .data(masked), .crc_out(crc_next));

    // early TLAST at word w: the (3-w) zero beats are skipped with A^(3-w), applied at the OUTPUT
    reg  [1:0]  skip_k;                 // zero beats elided for the FLIT held in crc_reg (0..3)
    wire [31:0] crc_skip_out;
    crc32_zero_skip u_skip (.crc_in(crc_reg), .k(skip_k), .crc_out(crc_skip_out));
    integer kz;

    assign s_axis_tready = (state == ACCUM) || (state == PRESENT && m_flit_ready);
    wire accept = s_axis_tvalid && s_axis_tready;
    assign m_flit_valid  = (state == PRESENT);
    assign m_flit_data       = flit_buf;
    assign m_flit_crc        = ~crc_skip_out;      // zero-skip (A^k) then final XOR
    assign m_flit_tkeep      = flit_keep_buf;
    assign m_flit_tlasts     = flit_tlast_buf;
    assign m_flit_beat_valid = flit_beat_valid_buf;

    // ---- control: the only flops that need reset ----------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= ACCUM;
            word_idx       <= 2'd0;
            fresh          <= 1'b1;
            m_flit_partial <= 1'b0;
        end else begin
            if (accept) begin
                // state is ACCUM, or PRESENT being handed off (word_idx == 0)
                fresh <= 1'b0;
                if (s_axis_tlast) begin
                    m_flit_partial <= (word_idx != 2'd3);
                    state    <= PRESENT;
                    word_idx <= 2'd0;
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

    // ---- datapath: NO reset (v7) --------------------------------------------
    // Every word of flit_buf / keep / tlast / beat_valid is written (by an accepted
    // beat or by the zero-fill of an early TLAST) before state can become PRESENT,
    // crc_reg is only used as a seed when `fresh` = 0 (i.e. after a beat of the
    // current FLIT was accepted), and m_flit_crc / m_flit_data / sideband are only
    // meaningful while m_flit_valid = 1.  Hence none of these flops needs a reset
    // value; dropping it removes ~2.4k reset loads (rst_n fan-out) and area.
    always @(posedge clk) begin
        if (accept) begin
            flit_buf[word_idx*TDATA_WIDTH +: TDATA_WIDTH] <= masked;
            flit_keep_buf[word_idx*(TDATA_WIDTH/8) +: (TDATA_WIDTH/8)] <= s_axis_tkeep;
            flit_tlast_buf[word_idx]      <= s_axis_tlast;
            flit_beat_valid_buf[word_idx] <= 1'b1;
            crc_reg <= crc_next;
            skip_k  <= s_axis_tlast ? (2'd3 - word_idx) : 2'd0;   // only read while PRESENT
            if (s_axis_tlast) begin
                for (kz = 1; kz < 4; kz = kz + 1)      // zero-fill words after the last one
                    if (kz > word_idx) begin
                        flit_buf[kz*TDATA_WIDTH +: TDATA_WIDTH] <= {TDATA_WIDTH{1'b0}};
                        flit_keep_buf[kz*(TDATA_WIDTH/8) +: (TDATA_WIDTH/8)] <= {(TDATA_WIDTH/8){1'b0}};
                        flit_tlast_buf[kz] <= 1'b0;
                        flit_beat_valid_buf[kz] <= 1'b0;
                    end
            end
        end
    end
endmodule
