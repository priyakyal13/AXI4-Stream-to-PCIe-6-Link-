`timescale 1ns/1ps

module tb_layer4_flit_to_phy_lanes;

    localparam DATA_BITS = 2048;
    localparam CRC_BITS  = 32;
    localparam NUM_LANES = 4;
    localparam SYM_BITS  = 2;
    localparam TOTAL_BITS    = DATA_BITS + CRC_BITS;   // 2080
    localparam TOTAL_SYMBOLS = TOTAL_BITS / SYM_BITS;  // 1040
    localparam LANE_BITS     = TOTAL_BITS / NUM_LANES; // 520
    localparam CLK_PERIOD = 10;

    reg clk, rst_n;
    reg  [DATA_BITS-1:0] s_flit_data;
    reg  [CRC_BITS-1:0]  s_flit_crc;
    reg                  s_flit_valid;
    wire                 s_flit_ready;

    wire [LANE_BITS-1:0] m_lane0_data, m_lane1_data, m_lane2_data, m_lane3_data;
    wire                 m_lane_valid;
    reg                  m_lane_ready;

    integer pass_count = 0;
    integer fail_count = 0;

    layer4_flit_to_phy_lanes #(
        .DATA_BITS(DATA_BITS), .CRC_BITS(CRC_BITS),
        .NUM_LANES(NUM_LANES), .SYM_BITS(SYM_BITS)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .s_flit_data(s_flit_data), .s_flit_crc(s_flit_crc), .s_flit_valid(s_flit_valid), .s_flit_ready(s_flit_ready),
        .m_lane0_data(m_lane0_data), .m_lane1_data(m_lane1_data),
        .m_lane2_data(m_lane2_data), .m_lane3_data(m_lane3_data),
        .m_lane_valid(m_lane_valid), .m_lane_ready(m_lane_ready)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    // ---------------- golden reference model ----------------
    // Explicit lookup table rather than the DUT's XOR formula
    // ({val[1], val[1]^val[0]}) — same standard Gray-code mapping,
    // written a structurally different way so the two aren't just
    // the same expression typed twice.
    function [SYM_BITS-1:0] gray_ref;
        input [SYM_BITS-1:0] val;
        begin
            case (val)
                2'b00: gray_ref = 2'b00;
                2'b01: gray_ref = 2'b01;
                2'b10: gray_ref = 2'b11;
                2'b11: gray_ref = 2'b10;
            endcase
        end
    endfunction

    task reset_dut;
        begin
            rst_n = 0;
            s_flit_valid = 0;
            s_flit_data  = 0;
            s_flit_crc   = 0;
            m_lane_ready = 1;
            repeat (3) @(posedge clk);
            rst_n = 1;
            @(posedge clk);
        end
    endtask

    task send_flit(input [DATA_BITS-1:0] data, input [CRC_BITS-1:0] crc);
        begin
            @(negedge clk);
            s_flit_data  = data;
            s_flit_crc   = crc;
            s_flit_valid = 1;
            @(posedge clk);
            while (s_flit_ready !== 1'b1) @(posedge clk);
            @(negedge clk);
            s_flit_valid = 0;
        end
    endtask

    task check_lanes(input [DATA_BITS-1:0] data, input [CRC_BITS-1:0] crc, input [255:0] label);
        reg [TOTAL_BITS-1:0] combined;
        reg [LANE_BITS-1:0]  exp_lane [0:3];
        integer sym_i, lane, pos;
        reg [SYM_BITS-1:0] raw_sym, gray_sym;
        begin
            combined = {crc, data};
            for (sym_i = 0; sym_i < TOTAL_SYMBOLS; sym_i = sym_i + 1) begin
                lane = sym_i % NUM_LANES;
                pos  = sym_i / NUM_LANES;
                raw_sym  = combined[sym_i*SYM_BITS +: SYM_BITS];
                gray_sym = gray_ref(raw_sym);
                exp_lane[lane][pos*SYM_BITS +: SYM_BITS] = gray_sym;
            end

            @(posedge clk);
            while (!m_lane_valid) @(posedge clk);
            @(negedge clk);

            if (m_lane0_data === exp_lane[0]) pass_count = pass_count + 1;
            else begin fail_count = fail_count + 1; $display("FAIL [%0s]: lane0 mismatch", label); end

            if (m_lane1_data === exp_lane[1]) pass_count = pass_count + 1;
            else begin fail_count = fail_count + 1; $display("FAIL [%0s]: lane1 mismatch", label); end

            if (m_lane2_data === exp_lane[2]) pass_count = pass_count + 1;
            else begin fail_count = fail_count + 1; $display("FAIL [%0s]: lane2 mismatch", label); end

            if (m_lane3_data === exp_lane[3]) pass_count = pass_count + 1;
            else begin fail_count = fail_count + 1; $display("FAIL [%0s]: lane3 mismatch", label); end

            @(posedge clk);
        end
    endtask

    initial begin
        clk = 0;
        reset_dut;

        // -------- Test 1: all-zero FLIT (every symbol = 00 -> gray 00) --------
        send_flit({DATA_BITS{1'b0}}, {CRC_BITS{1'b0}});
        check_lanes({DATA_BITS{1'b0}}, {CRC_BITS{1'b0}}, "all_zero");

        // -------- Test 2: all-one FLIT (every symbol = 11 -> gray 10) --------
        send_flit({DATA_BITS{1'b1}}, {CRC_BITS{1'b1}});
        check_lanes({DATA_BITS{1'b1}}, {CRC_BITS{1'b1}}, "all_one");

        // -------- Test 3: known symbol-value counter pattern to verify
        //                  striping ORDER, not just gray-code correctness.
        //                  Each 2-bit slot i holds (i % 4), so lane
        //                  assignment can be checked position-by-position. --------
        begin : gen_counter_pattern
            reg [DATA_BITS-1:0] cdata;
            reg [CRC_BITS-1:0]  ccrc;
            integer i;
            reg [TOTAL_BITS-1:0] full;
            for (i = 0; i < TOTAL_SYMBOLS; i = i + 1)
                full[i*SYM_BITS +: SYM_BITS] = i % 4;
            ccrc  = full[TOTAL_BITS-1 -: CRC_BITS];
            cdata = full[DATA_BITS-1:0];
            send_flit(cdata, ccrc);
            check_lanes(cdata, ccrc, "counter_pattern");
        end

        // -------- Test 4: alternating 0xA5.../0x5A... pattern --------
        send_flit({(DATA_BITS/8){8'hA5}}, {(CRC_BITS/8){8'h5A}});
        check_lanes({(DATA_BITS/8){8'hA5}}, {(CRC_BITS/8){8'h5A}}, "alternating_pattern");

        // -------- Test 5: back-to-back FLITs (no idle cycles between) --------
        send_flit({DATA_BITS{1'b0}}, 32'hDEAD_BEEF);
        check_lanes({DATA_BITS{1'b0}}, 32'hDEAD_BEEF, "back_to_back_1");
        send_flit({DATA_BITS{1'b1}}, 32'hCAFE_F00D);
        check_lanes({DATA_BITS{1'b1}}, 32'hCAFE_F00D, "back_to_back_2");

        // -------- Test 6: backpressure — m_lane_ready held low for several
        //                  cycles after the lane outputs go valid. Verifies
        //                  the striped lane data holds stable while stalled
        //                  and s_flit_ready correctly stays low (no new FLIT
        //                  accepted) until the stall is released. --------
        begin : backpressure_test
            reg [TOTAL_BITS-1:0] combined_bp;
            reg [LANE_BITS-1:0]  exp_lane_bp [0:3];
            integer sym_i, lane, pos, r;
            reg [SYM_BITS-1:0] raw_sym, gray_sym;

            combined_bp = {32'h1357_9BDF, {(DATA_BITS/8){8'h3C}}};
            for (sym_i = 0; sym_i < TOTAL_SYMBOLS; sym_i = sym_i + 1) begin
                lane = sym_i % NUM_LANES;
                pos  = sym_i / NUM_LANES;
                raw_sym  = combined_bp[sym_i*SYM_BITS +: SYM_BITS];
                gray_sym = gray_ref(raw_sym);
                exp_lane_bp[lane][pos*SYM_BITS +: SYM_BITS] = gray_sym;
            end

            m_lane_ready = 0; // stall before the FLIT even arrives
            @(negedge clk);
            s_flit_data  = {(DATA_BITS/8){8'h3C}};
            s_flit_crc   = 32'h1357_9BDF;
            s_flit_valid = 1;
            @(posedge clk);
            while (s_flit_ready !== 1'b1) @(posedge clk);
            @(negedge clk);
            s_flit_valid = 0;

            @(posedge clk);
            while (!m_lane_valid) @(posedge clk);

            for (r = 0; r < 5; r = r + 1) begin
                @(negedge clk);
                if (m_lane_valid === 1'b1 &&
                    m_lane0_data === exp_lane_bp[0] && m_lane1_data === exp_lane_bp[1] &&
                    m_lane2_data === exp_lane_bp[2] && m_lane3_data === exp_lane_bp[3])
                    pass_count = pass_count + 1;
                else begin
                    fail_count = fail_count + 1;
                    $display("FAIL [backpressure]: lane outputs did not hold stable while stalled");
                end
                if (s_flit_ready === 1'b0) pass_count = pass_count + 1;
                else begin fail_count = fail_count + 1; $display("FAIL [backpressure]: s_flit_ready should stay low while stalled"); end
            end

            @(negedge clk);
            m_lane_ready = 1; // release
            check_lanes({(DATA_BITS/8){8'h3C}}, 32'h1357_9BDF, "backpressure_release");
        end

        // -------- Test 7: reset mid-stripe clears state cleanly --------
        @(negedge clk);
        s_flit_data  = {DATA_BITS{1'b1}};
        s_flit_crc   = 32'hFFFF_FFFF;
        s_flit_valid = 1;
        @(posedge clk);
        while (s_flit_ready !== 1'b1) @(posedge clk);
        @(negedge clk);
        s_flit_valid = 0;
        reset_dut;
        if (s_flit_ready === 1'b1 && m_lane_valid === 1'b0) pass_count = pass_count + 1;
        else begin fail_count = fail_count + 1; $display("FAIL: state not clean after mid-stripe reset"); end

        $display("=================================================");
        $display("TESTS PASSED: %0d   TESTS FAILED: %0d", pass_count, fail_count);
        $display("=================================================");
        if (fail_count == 0)
            $display("RESULT: ALL TESTS PASSED");
        else
            $display("RESULT: FAILURES PRESENT");

        $finish;
    end

    initial begin
        $dumpfile("sim/dump_layer4_flit_to_phy_lanes.vcd");
        $dumpvars(0, tb_layer4_flit_to_phy_lanes);
    end

endmodule
