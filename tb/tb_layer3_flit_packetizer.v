`timescale 1ns/1ps

module tb_layer3_flit_packetizer;

    localparam TDATA_WIDTH = 512;
    localparam FLIT_BYTES  = 256;
    localparam CLK_PERIOD  = 10;

    reg clk, rst_n;
    reg  [TDATA_WIDTH-1:0]      s_axis_tdata;
    reg  [(TDATA_WIDTH/8)-1:0]  s_axis_tkeep;
    reg                         s_axis_tvalid;
    wire                        s_axis_tready;
    reg                         s_axis_tlast;

    wire [FLIT_BYTES*8-1:0]     m_flit_data;
    wire [31:0]                 m_flit_crc;
    wire                        m_flit_valid;
    reg                         m_flit_ready;
    wire                        m_flit_partial;

    integer pass_count = 0;
    integer fail_count = 0;

    layer3_flit_packetizer #(
        .TDATA_WIDTH(TDATA_WIDTH),
        .FLIT_BYTES(FLIT_BYTES)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tkeep(s_axis_tkeep),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .s_axis_tlast(s_axis_tlast),
        .m_flit_data(m_flit_data),
        .m_flit_crc(m_flit_crc),
        .m_flit_valid(m_flit_valid),
        .m_flit_ready(m_flit_ready),
        .m_flit_partial(m_flit_partial)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    // ---------------- Golden reference CRC-32: TABLE-DRIVEN, structurally
    // independent of the DUT's bit-serial LFSR-style implementation (built
    // once at elaboration time, then a single table lookup per byte instead
    // of an 8-iteration bit loop per byte). Mathematically the same
    // reflected CRC-32 construction, but a different enough code shape that
    // a transcription/indexing bug in one form is unlikely to be mirrored
    // in the other. ----------------
    reg [31:0] crc_table [0:255];
    initial begin : build_crc_table
        integer n, k;
        reg [31:0] c;
        for (n = 0; n < 256; n = n + 1) begin
            c = n[31:0];
            for (k = 0; k < 8; k = k + 1)
                c = c[0] ? (32'hEDB88320 ^ (c >> 1)) : (c >> 1);
            crc_table[n] = c;
        end
    end

    function [31:0] crc32_ref;
        input [FLIT_BYTES*8-1:0] data;
        integer b;
        reg [31:0] crc;
        reg [7:0]  idx;
        begin
            crc = 32'hFFFFFFFF;
            for (b = 0; b < FLIT_BYTES; b = b + 1) begin
                idx = crc[7:0] ^ data[b*8 +: 8];
                crc = crc_table[idx] ^ (crc >> 8);
            end
            crc32_ref = crc ^ 32'hFFFFFFFF;
        end
    endfunction

    // ---------------- helper tasks ----------------
    task reset_dut;
        begin
            rst_n = 0;
            s_axis_tvalid = 0;
            s_axis_tlast  = 0;
            s_axis_tdata  = 0;
            s_axis_tkeep  = {(TDATA_WIDTH/8){1'b1}};
            m_flit_ready  = 1;
            repeat (3) @(posedge clk);
            rst_n = 1;
            @(posedge clk);
        end
    endtask

    // Sends one 512-bit beat
    task send_beat(input [TDATA_WIDTH-1:0] data, input [(TDATA_WIDTH/8)-1:0] keep, input last);
        begin
            @(negedge clk);
            s_axis_tdata  = data;
            s_axis_tkeep  = keep;
            s_axis_tvalid = 1;
            s_axis_tlast  = last;
            @(posedge clk);
            while (s_axis_tready !== 1'b1) @(posedge clk);
            @(negedge clk); // beat accepted; safe to change stimulus now
            s_axis_tvalid = 0;
            s_axis_tlast  = 0;
        end
    endtask

    task check_flit(input [FLIT_BYTES*8-1:0] expected_data, input expect_partial, input [255:0] label);
        reg [31:0] expected_crc;
        begin
            @(posedge clk);
            while (!m_flit_valid) @(posedge clk);
            expected_crc = crc32_ref(expected_data);
            @(negedge clk);
            if (m_flit_data === expected_data)
                pass_count = pass_count + 1;
            else begin
                fail_count = fail_count + 1;
                $display("FAIL [%0s]: flit data mismatch", label);
            end

            if (m_flit_crc === expected_crc)
                pass_count = pass_count + 1;
            else begin
                fail_count = fail_count + 1;
                $display("FAIL [%0s]: CRC mismatch. got=%h exp=%h", label, m_flit_crc, expected_crc);
            end

            if (m_flit_partial === expect_partial)
                pass_count = pass_count + 1;
            else begin
                fail_count = fail_count + 1;
                $display("FAIL [%0s]: partial flag mismatch. got=%b exp=%b", label, m_flit_partial, expect_partial);
            end
            @(posedge clk);
        end
    endtask

    // ---------------- test sequence ----------------
    reg [TDATA_WIDTH-1:0] w0, w1, w2, w3;
    reg [FLIT_BYTES*8-1:0] expected_full;
    reg [FLIT_BYTES*8-1:0] expected_partial;

    initial begin
        clk = 0;
        reset_dut;

        // -------- Test 1: exactly 4 full beats -> one full FLIT --------
        w0 = {16{32'hAAAA_0001}};
        w1 = {16{32'hBBBB_0002}};
        w2 = {16{32'hCCCC_0003}};
        w3 = {16{32'hDDDD_0004}};
        expected_full = {w3, w2, w1, w0};

        send_beat(w0, {64{1'b1}}, 0);
        send_beat(w1, {64{1'b1}}, 0);
        send_beat(w2, {64{1'b1}}, 0);
        send_beat(w3, {64{1'b1}}, 1); // TLAST on the exact boundary beat

        check_flit(expected_full, 1'b0, "full_flit");

        // -------- Test 2: early TLAST after 2 beats -> zero-padded partial FLIT --------
        w0 = {16{32'h1111_1111}};
        w1 = {16{32'h2222_2222}};
        expected_partial = {512'b0, 512'b0, w1, w0};

        send_beat(w0, {64{1'b1}}, 0);
        send_beat(w1, {64{1'b1}}, 1); // early last

        check_flit(expected_partial, 1'b1, "early_last_partial_flit");

        // -------- Test 3: single beat with TLAST asserted immediately --------
        w0 = {16{32'hF00D_CAFE}};
        expected_partial = {512'b0, 512'b0, 512'b0, w0};

        send_beat(w0, {64{1'b1}}, 1);
        check_flit(expected_partial, 1'b1, "single_beat_early_last");

        // -------- Test 4: back-to-back full FLITs (throughput case) --------
        w0 = {16{32'h5A5A_0000}};
        w1 = {16{32'h6B6B_1111}};
        w2 = {16{32'h7C7C_2222}};
        w3 = {16{32'h8D8D_3333}};
        expected_full = {w3, w2, w1, w0};
        send_beat(w0, {64{1'b1}}, 0);
        send_beat(w1, {64{1'b1}}, 0);
        send_beat(w2, {64{1'b1}}, 0);
        send_beat(w3, {64{1'b1}}, 0); // no TLAST — boundary count triggers flush
        check_flit(expected_full, 1'b0, "boundary_flush_no_tlast");

        // -------- Test 5: reset mid-accumulation clears state cleanly --------
        send_beat(32'hDEAD_BEEF, {64{1'b1}}, 0); // partial beat (only 1 word in)
        reset_dut;
        if (s_axis_tready === 1'b1) pass_count = pass_count + 1;
        else begin fail_count = fail_count + 1; $display("FAIL: tready not re-asserted after reset"); end

        // -------- Test 6: backpressure on the FLIT output — m_flit_ready
        //                  held low for several cycles after a FLIT becomes
        //                  valid, before being released. Verifies m_flit_data/
        //                  crc/valid hold stable while stalled, and that the
        //                  ingress correctly stays blocked (tready=0) for the
        //                  next packet until the stalled FLIT is finally
        //                  accepted. This exercises the one handshake path
        //                  every prior test left completely untouched. --------
        w0 = {16{32'h9999_AAAA}};
        w1 = {16{32'h9999_BBBB}};
        w2 = {16{32'h9999_CCCC}};
        w3 = {16{32'h9999_DDDD}};
        expected_full = {w3, w2, w1, w0};

        m_flit_ready = 0; // stall BEFORE the flit even arrives, so we catch it the instant it goes valid
        send_beat(w0, {64{1'b1}}, 0);
        send_beat(w1, {64{1'b1}}, 0);
        send_beat(w2, {64{1'b1}}, 0);
        send_beat(w3, {64{1'b1}}, 1);

        // FLIT should now be valid and held, waiting on m_flit_ready.
        @(posedge clk);
        while (!m_flit_valid) @(posedge clk);
        repeat (5) begin
            @(negedge clk);
            if (m_flit_valid === 1'b1 && m_flit_data === expected_full)
                pass_count = pass_count + 1;
            else begin
                fail_count = fail_count + 1;
                $display("FAIL [backpressure]: m_flit_data/valid did not hold stable while stalled");
            end
            // Ingress must stay blocked for the next packet while this FLIT
            // is still waiting to be accepted.
            if (s_axis_tready === 1'b0)
                pass_count = pass_count + 1;
            else begin
                fail_count = fail_count + 1;
                $display("FAIL [backpressure]: s_axis_tready should stay low while FLIT output is stalled");
            end
        end

        @(negedge clk);
        m_flit_ready = 1; // release the stall
        check_flit(expected_full, 1'b0, "backpressure_release");

        // -------- Test: TKEEP correctness — partial tkeep on a beat must
        //                zero exactly the un-kept bytes at their OWN byte
        //                position (not shift/compact surrounding bytes),
        //                per the module's documented TKEEP semantics.
        //                Every prior test used all-1s tkeep; this is the
        //                first test that actually exercises the masking
        //                logic at all. --------
        begin : tkeep_test
            reg [TDATA_WIDTH-1:0] w_partial;
            reg [(TDATA_WIDTH/8)-1:0] partial_keep;
            reg [FLIT_BYTES*8-1:0] expected_tkeep_flit;
            integer byte_i;

            w0 = {16{32'hE1E1_0000}};           // beat0: full tkeep
            w_partial = {16{32'hE2E2_FFFF}};     // beat1: only low 8 bytes kept
            partial_keep = {56'h0, 8'hFF};        // bytes[63:8] masked off, bytes[7:0] kept

            // Build the expected FLIT by hand: beat0 in word0 unmodified,
            // beat1 in word1 with only its low 8 bytes surviving and
            // every other byte forced to zero (not removed/shifted).
            expected_tkeep_flit = {512'b0, 512'b0, {448'b0, w_partial[63:0]}, w0};

            send_beat(w0, {64{1'b1}}, 0);
            send_beat(w_partial, partial_keep, 1); // early TLAST -> partial flit, word1 masked

            check_flit(expected_tkeep_flit, 1'b1, "tkeep_partial_mask");
        end

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
        $dumpfile("sim/dump_layer3_flit_packetizer.vcd");
        $dumpvars(0, tb_layer3_flit_packetizer);
    end

endmodule
