// =============================================================
// layer4_flit_to_phy_lanes.v   (Stage 2 rewrite - v2, drop-in)
//
// Same ports / same behaviour as Stage 1:
//   FLIT (2048-bit data + 32-bit CRC = 2080 bits)
//     -> 1040 two-bit symbols, symbol i -> lane (i % 4), slot (i / 4)
//     -> each symbol Gray coded (00->00, 01->01, 10->11, 11->10)
//     -> four 520-bit lane words, valid/ready handshaked.
//
// What changed (why Yosys could not finish the Stage 1 version):
//   Stage 1 ran a 1040-iteration loop of non-blocking writes into partial
//   slices of four 520-bit registers inside a clocked process, and kept
//   TWO copies of the data (combined_reg + 4 lane registers = 4160 FFs).
//   Striping + Gray coding is pure WIRING plus one tiny gate per symbol, so
//   it is now a combinational generate block fed by ONE 2080-bit register.
//   -> ~2080 flip-flops instead of ~4160, no big sequential loop.
// =============================================================
module layer4_flit_to_phy_lanes #(
    parameter DATA_BITS  = 2048,
    parameter CRC_BITS   = 32,
    parameter NUM_LANES  = 4,
    parameter SYM_BITS   = 2
)(
    input                              clk,
    input                              rst_n,

    input      [DATA_BITS-1:0]         s_flit_data,
    input      [CRC_BITS-1:0]          s_flit_crc,
    input                              s_flit_valid,
    output                             s_flit_ready,

    output     [((DATA_BITS+CRC_BITS)/NUM_LANES)-1:0] m_lane0_data,
    output     [((DATA_BITS+CRC_BITS)/NUM_LANES)-1:0] m_lane1_data,
    output     [((DATA_BITS+CRC_BITS)/NUM_LANES)-1:0] m_lane2_data,
    output     [((DATA_BITS+CRC_BITS)/NUM_LANES)-1:0] m_lane3_data,
    output                             m_lane_valid,
    input                              m_lane_ready
);

    localparam TOTAL_BITS    = DATA_BITS + CRC_BITS;     // 2080
    localparam TOTAL_SYMBOLS = TOTAL_BITS / SYM_BITS;    // 1040
    localparam LANE_BITS     = TOTAL_BITS / NUM_LANES;   // 520
    localparam LANE_SYMS     = TOTAL_SYMBOLS / NUM_LANES;// 260

    initial begin
        if (SYM_BITS != 2 || NUM_LANES != 4)
            $fatal(1, "layer4_flit_to_phy_lanes: ports are built for 4 lanes x 2-bit symbols");
        if (TOTAL_BITS % SYM_BITS != 0 || TOTAL_SYMBOLS % NUM_LANES != 0)
            $fatal(1, "layer4_flit_to_phy_lanes: widths must divide evenly");
    end

    localparam ACCUM = 1'b0, PRESENT = 1'b1;

    reg                   state;
    reg [TOTAL_BITS-1:0]  combined_reg;     // {CRC, DATA}: symbol 0 = LSB of DATA

    assign s_flit_ready = (state == ACCUM);
    assign m_lane_valid = (state == PRESENT);

    // ---- combinational striping + Gray coding (wiring + 1 gate/symbol) ----
    wire [NUM_LANES*LANE_BITS-1:0] lanes_flat;
    genvar p, l;
    generate
        for (p = 0; p < LANE_SYMS; p = p + 1) begin : g_pos
            for (l = 0; l < NUM_LANES; l = l + 1) begin : g_lane
                wire [1:0] raw = combined_reg[(p*NUM_LANES + l)*2 +: 2];
                assign lanes_flat[l*LANE_BITS + p*2 +: 2] = {raw[1], raw[1] ^ raw[0]};
            end
        end
    endgenerate

    assign m_lane0_data = lanes_flat[0*LANE_BITS +: LANE_BITS];
    assign m_lane1_data = lanes_flat[1*LANE_BITS +: LANE_BITS];
    assign m_lane2_data = lanes_flat[2*LANE_BITS +: LANE_BITS];
    assign m_lane3_data = lanes_flat[3*LANE_BITS +: LANE_BITS];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= ACCUM;
            combined_reg <= {TOTAL_BITS{1'b0}};
        end else begin
            case (state)
                ACCUM:   if (s_flit_valid) begin
                             combined_reg <= {s_flit_crc, s_flit_data};
                             state        <= PRESENT;
                         end
                PRESENT: if (m_lane_ready)
                             state <= ACCUM;
            endcase
        end
    end
endmodule
