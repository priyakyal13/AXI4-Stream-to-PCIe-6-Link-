// =============================================================
// layer4_flit_to_phy_lanes.v
//
// Layer 4 (PCIe Protocol-to-PHY Layer) per the SARCathon reference
// architecture:
//
//   FLIT (256B data + 32-bit CRC) --> [this module] --> 4-lane
//   parallel symbol bus to analog PHY [To Multi-Lane SerDes]
//
// Behavior:
//   - Consumes one FLIT (2048-bit data + 32-bit CRC = 2080 bits)
//     from the Link Layer.
//   - Splits the 2080-bit payload into 1040 two-bit symbols.
//   - Round-robin striping across 4 lanes: symbol i -> lane (i%4),
//     position (i/4) within that lane. 1040/4 = 260 symbols/lane
//     exactly (2080 is lane- and symbol-aligned by construction,
//     since FLIT size and lane count were chosen to divide evenly).
//   - Each 2-bit symbol is Gray-coded (00->00, 01->01, 10->11,
//     11->10) before being placed on the lane bus, matching the
//     "Gray Coding & PAM4 Mapping (2 bits -> 1 symbol)" step in
//     the block diagram. The mapped 2-bit code is what a PAM4
//     driver would decode into one of 4 voltage levels; the
//     analog level generation itself is out of scope for RTL sim.
//
// This module presents each lane's full symbol burst for one FLIT
// as a single wide parallel word (520 bits = 260 symbols x 2 bits),
// valid/ready handshaked, rather than serializing lane-by-lane —
// serialization to the SerDes is a mechanical next step once a
// PHY model exists to serialize into.
// =============================================================

module layer4_flit_to_phy_lanes #(
    parameter DATA_BITS  = 2048,
    parameter CRC_BITS   = 32,
    parameter NUM_LANES  = 4,
    parameter SYM_BITS   = 2
)(
    input                              clk,
    input                              rst_n,

    // ---------------- FLIT input (from Link Layer) ----------------
    input      [DATA_BITS-1:0]         s_flit_data,
    input      [CRC_BITS-1:0]          s_flit_crc,
    input                              s_flit_valid,
    output reg                         s_flit_ready,

    // ---------------- Lane-striped symbol output ----------------
    output reg [((DATA_BITS+CRC_BITS)/NUM_LANES)-1:0] m_lane0_data,
    output reg [((DATA_BITS+CRC_BITS)/NUM_LANES)-1:0] m_lane1_data,
    output reg [((DATA_BITS+CRC_BITS)/NUM_LANES)-1:0] m_lane2_data,
    output reg [((DATA_BITS+CRC_BITS)/NUM_LANES)-1:0] m_lane3_data,
    output reg                         m_lane_valid,
    input                              m_lane_ready
);

    localparam TOTAL_BITS      = DATA_BITS + CRC_BITS;              // 2080
    localparam TOTAL_SYMBOLS   = TOTAL_BITS / SYM_BITS;              // 1040
    localparam LANE_BITS       = TOTAL_BITS / NUM_LANES;             // 520

    // Sanity checks on parameterization (elaboration-time).
    // Widths must divide evenly for the round-robin scheme below.
    initial begin
        if (TOTAL_BITS % SYM_BITS != 0)
            $fatal(1, "layer4_flit_to_phy_lanes: TOTAL_BITS must be a multiple of SYM_BITS");
        if (TOTAL_SYMBOLS % NUM_LANES != 0)
            $fatal(1, "layer4_flit_to_phy_lanes: TOTAL_SYMBOLS must be a multiple of NUM_LANES");
    end

    localparam ACCUM   = 2'd0,
               STRIPE   = 2'd1,
               PRESENT  = 2'd2;

    reg [1:0]              state;
    reg [TOTAL_BITS-1:0]   combined_reg;

    // Standard 2-bit Gray code: 0->00, 1->01, 2->11, 3->10
    function [SYM_BITS-1:0] gray_encode;
        input [SYM_BITS-1:0] val;
        begin
            gray_encode = {val[1], val[1] ^ val[0]};
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= ACCUM;
            s_flit_ready  <= 1'b1;
            combined_reg  <= {TOTAL_BITS{1'b0}};
            m_lane0_data  <= {LANE_BITS{1'b0}};
            m_lane1_data  <= {LANE_BITS{1'b0}};
            m_lane2_data  <= {LANE_BITS{1'b0}};
            m_lane3_data  <= {LANE_BITS{1'b0}};
            m_lane_valid  <= 1'b0;
        end else begin
            case (state)

                ACCUM: begin
                    s_flit_ready <= 1'b1;
                    if (s_flit_valid && s_flit_ready) begin
                        // CRC placed at the top of the combined word so
                        // symbol 0 is the LSB of the FLIT data — matches
                        // the golden model used in verification.
                        combined_reg <= {s_flit_crc, s_flit_data};
                        s_flit_ready <= 1'b0;
                        state        <= STRIPE;
                    end
                end

                STRIPE: begin
                    integer sym_i, lane, pos;
                    reg [SYM_BITS-1:0] raw_sym, gray_sym;
                    for (sym_i = 0; sym_i < TOTAL_SYMBOLS; sym_i = sym_i + 1) begin
                        lane    = sym_i % NUM_LANES;
                        pos     = sym_i / NUM_LANES;
                        raw_sym = combined_reg[sym_i*SYM_BITS +: SYM_BITS];
                        gray_sym = gray_encode(raw_sym);
                        case (lane)
                            0: m_lane0_data[pos*SYM_BITS +: SYM_BITS] <= gray_sym;
                            1: m_lane1_data[pos*SYM_BITS +: SYM_BITS] <= gray_sym;
                            2: m_lane2_data[pos*SYM_BITS +: SYM_BITS] <= gray_sym;
                            3: m_lane3_data[pos*SYM_BITS +: SYM_BITS] <= gray_sym;
                        endcase
                    end
                    m_lane_valid <= 1'b1;
                    state        <= PRESENT;
                end

                PRESENT: begin
                    if (m_lane_valid && m_lane_ready) begin
                        m_lane_valid <= 1'b0;
                        s_flit_ready <= 1'b1;
                        state        <= ACCUM;
                    end
                end

                default: state <= ACCUM;

            endcase
        end
    end

endmodule
