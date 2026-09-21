// =============================================================
// layer3_flit_packetizer.v
//
// Layer 3 (Link Layer: FLIT packetization + CRC) per the SARCathon
// reference architecture, as its OWN standalone block — split out
// from the fused implementation kept at
// legacy_fused_layer1_3_axis_to_flit.v.
//
// Interface-compatible with a direct AXI4-Stream master (as in the
// legacy fused version), but intended to sit downstream of
// layer1_axis_stream_ingress.v (Layer 1) in the split pipeline:
//
//   AXI4-Stream (from Layer 1) --> [this module] --> FLIT (256B) + CRC32
//
// The accumulation FSM and CRC math are UNCHANGED from the fused
// version (already verified there) — only the module's role in the
// pipeline changed, not its logic. Layer 2 (Interconnect
// crossbar/arbiter) sits further upstream, ahead of Layer 1, in the
// full split pipeline (see top_4layer_true_split.v).
//
// Behavior:
//   - Accepts 512-bit AXI4-Stream beats (TDATA/TVALID/TREADY/TLAST/TKEEP).
//   - 4 beats = 2048 bits = 256 bytes = one fixed-size FLIT
//     (Flow Information Unit), matching the spec's "256-Byte FIU".
//   - On the 4th beat, or on an early TLAST, the accumulated bytes
//     are zero-padded to 256B and a CRC-32 (IEEE 802.3 polynomial,
//     0x04C11DB7, byte-serial, reflected/LSB-first form) is computed
//     over the padded FLIT.
//   - The FLIT (2048-bit data + 32-bit CRC) is presented on a
//     single-beat valid/ready output interface representing the
//     "System-Synchronous Bus" in the block diagram. Serializing
//     this to a narrower bus (e.g. 256-bit) is a mechanical next
//     step, deferred to keep this block independently verifiable.
// =============================================================

module layer3_flit_packetizer #(
    parameter TDATA_WIDTH   = 512,
    parameter FLIT_BYTES    = 256,
    parameter WORDS_PER_FLIT = (FLIT_BYTES*8) / TDATA_WIDTH   // = 4
)(
    input                           clk,
    input                           rst_n,

    // ---------------- AXI4-Stream Slave (ingress) ----------------
    input      [TDATA_WIDTH-1:0]    s_axis_tdata,
    input      [(TDATA_WIDTH/8)-1:0] s_axis_tkeep,
    input                           s_axis_tvalid,
    output reg                      s_axis_tready,
    input                           s_axis_tlast,

    // ---------------- FLIT output (Link Layer) --------------------
    output reg [FLIT_BYTES*8-1:0]  m_flit_data,
    output reg [31:0]              m_flit_crc,
    output reg                     m_flit_valid,
    input                          m_flit_ready,
    output reg                     m_flit_partial   // 1 = flushed early (TLAST before full FLIT), zero-padded
);

    localparam WORD_IDX_W = (WORDS_PER_FLIT <= 1) ? 1 : $clog2(WORDS_PER_FLIT);

    // FSM states
    localparam ACCUM  = 1'b0,
               PRESENT = 1'b1;

    reg                          state;
    reg [FLIT_BYTES*8-1:0]       flit_buf;
    reg [WORD_IDX_W-1:0]         word_idx;

    // -------- byte-serial CRC-32 (IEEE 802.3, poly 0x04C11DB7) --------
    // Standard bit-reflected table-free update, one byte per call.
    function [31:0] crc32_byte;
        input [31:0] crc_in;
        input [7:0]  data;
        integer i;
        reg [31:0] crc;
        begin
            crc = crc_in ^ {24'b0, data};
            for (i = 0; i < 8; i = i + 1) begin
                if (crc[0])
                    crc = (crc >> 1) ^ 32'hEDB88320;
                else
                    crc = crc >> 1;
            end
            crc32_byte = crc;
        end
    endfunction

    // Compute CRC over the full padded FLIT combinationally when we
    // flush. Unrolled over FLIT_BYTES bytes (256 for the default config).
    function [31:0] crc32_flit;
        input [FLIT_BYTES*8-1:0] data;
        integer b;
        reg [31:0] crc;
        begin
            crc = 32'hFFFFFFFF;
            for (b = 0; b < FLIT_BYTES; b = b + 1)
                crc = crc32_byte(crc, data[b*8 +: 8]);
            crc32_flit = crc ^ 32'hFFFFFFFF;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= ACCUM;
            s_axis_tready  <= 1'b1;
            flit_buf       <= {(FLIT_BYTES*8){1'b0}};
            word_idx       <= {WORD_IDX_W{1'b0}};
            m_flit_data    <= {(FLIT_BYTES*8){1'b0}};
            m_flit_crc     <= 32'b0;
            m_flit_valid   <= 1'b0;
            m_flit_partial <= 1'b0;
        end else begin
            case (state)

                ACCUM: begin
                    s_axis_tready <= 1'b1;

                    if (s_axis_tvalid && s_axis_tready) begin
                        // Drop the current word into the buffer at word_idx.
                        // TKEEP bytes not asserted are zeroed (padding within
                        // a partial final word).
                        integer k;
                        for (k = 0; k < TDATA_WIDTH/8; k = k + 1) begin
                            if (s_axis_tkeep[k])
                                flit_buf[(word_idx*TDATA_WIDTH) + k*8 +: 8] <= s_axis_tdata[k*8 +: 8];
                            else
                                flit_buf[(word_idx*TDATA_WIDTH) + k*8 +: 8] <= 8'h00;
                        end

                        if (s_axis_tlast) begin
                            // Early or exact-boundary flush: zero-pad any
                            // remaining words (already zero from reset/last
                            // flush; only need to guard mid-stream garbage,
                            // which there is none since flit_buf holds only
                            // what's been written).
                            s_axis_tready <= 1'b0;
                            word_idx      <= {WORD_IDX_W{1'b0}};
                            m_flit_partial <= (word_idx != WORDS_PER_FLIT-1);
                            state         <= PRESENT;
                        end else if (word_idx == WORDS_PER_FLIT-1) begin
                            s_axis_tready  <= 1'b0;
                            word_idx       <= {WORD_IDX_W{1'b0}};
                            m_flit_partial <= 1'b0;
                            state          <= PRESENT;
                        end else begin
                            word_idx <= word_idx + 1'b1;
                        end
                    end
                end

                PRESENT: begin
                    m_flit_data  <= flit_buf;
                    m_flit_crc   <= crc32_flit(flit_buf);
                    m_flit_valid <= 1'b1;

                    if (m_flit_valid && m_flit_ready) begin
                        m_flit_valid  <= 1'b0;
                        flit_buf      <= {(FLIT_BYTES*8){1'b0}};
                        s_axis_tready <= 1'b1;
                        state         <= ACCUM;
                    end
                end

                default: state <= ACCUM;

            endcase
        end
    end

endmodule
