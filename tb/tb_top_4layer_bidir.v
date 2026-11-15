`timescale 1ns/1ps
// Self-checking end-to-end TX->lane->RX loopback regression.
// Covers exact beat reconstruction (including sparse TKEEP), early TLAST,
// multiple FLITs per packet, backpressure, CRC error drop, and post-error recovery.
module tb_top_4layer_bidir;
    localparam LANE_BITS = 596;
    reg clk = 1'b0;
    reg rst_n = 1'b0;

    reg [511:0] s0_data = 0;
    reg [63:0]  s0_keep = 0;
    reg s0_valid = 0, s0_last = 0;
    wire s0_ready;
    reg [511:0] s1_data = 0;
    reg [63:0]  s1_keep = 0;
    reg s1_valid = 0, s1_last = 0;
    wire s1_ready;

    wire [LANE_BITS-1:0] tx_lane0, tx_lane1, tx_lane2, tx_lane3;
    wire tx_lane_valid;
    wire tx_lane_ready;
    reg corrupt_enable = 0;
    wire [LANE_BITS-1:0] rx_lane0 = corrupt_enable ? (tx_lane0 ^ {{(LANE_BITS-1){1'b0}},1'b1}) : tx_lane0;
    wire [LANE_BITS-1:0] rx_lane1 = tx_lane1;
    wire [LANE_BITS-1:0] rx_lane2 = tx_lane2;
    wire [LANE_BITS-1:0] rx_lane3 = tx_lane3;
    wire rx_lane_valid = tx_lane_valid;
    wire rx_lane_ready;

    wire [511:0] m_data;
    wire [63:0]  m_keep;
    wire m_valid, m_last;
    reg m_ready = 0;
    wire rx_error;
    wire [1:0] rx_error_code;
    wire [31:0] rx_good_frames, rx_bad_frames;

    integer cycle_count = 0;
    always #5 clk = ~clk;
    always @(negedge clk) begin
        cycle_count = cycle_count + 1;
        if (!rst_n) m_ready = 1'b0;
        else        m_ready = ((cycle_count % 5) != 0); // inject repeatable backpressure
    end

    top_4layer_bidir dut (
        .clk(clk), .rst_n(rst_n),
        .s_axis0_tdata(s0_data), .s_axis0_tkeep(s0_keep), .s_axis0_tvalid(s0_valid),
        .s_axis0_tready(s0_ready), .s_axis0_tlast(s0_last),
        .s_axis1_tdata(s1_data), .s_axis1_tkeep(s1_keep), .s_axis1_tvalid(s1_valid),
        .s_axis1_tready(s1_ready), .s_axis1_tlast(s1_last),
        .m_tx_lane0_data(tx_lane0), .m_tx_lane1_data(tx_lane1),
        .m_tx_lane2_data(tx_lane2), .m_tx_lane3_data(tx_lane3),
        .m_tx_lane_valid(tx_lane_valid), .m_tx_lane_ready(tx_lane_ready),
        .s_rx_lane0_data(rx_lane0), .s_rx_lane1_data(rx_lane1),
        .s_rx_lane2_data(rx_lane2), .s_rx_lane3_data(rx_lane3),
        .s_rx_lane_valid(rx_lane_valid), .s_rx_lane_ready(rx_lane_ready),
        .m_axis_tdata(m_data), .m_axis_tkeep(m_keep), .m_axis_tvalid(m_valid),
        .m_axis_tready(m_ready), .m_axis_tlast(m_last),
        .rx_error(rx_error), .rx_error_code(rx_error_code),
        .rx_good_frames(rx_good_frames), .rx_bad_frames(rx_bad_frames)
    );
    assign tx_lane_ready = rx_lane_ready;

    reg [511:0] exp_data [0:127];
    reg [63:0] exp_keep [0:127];
    reg exp_last [0:127];
    integer q_wr = 0;
    integer q_rd = 0;
    integer failures = 0;
    integer beat_checks = 0;
    integer error_pulses = 0;

    // Compare only valid bytes semantically: TX intentionally zeroes TKEEP=0 bytes.
    always @(posedge clk) begin
        if (rst_n && m_valid && m_ready) begin
            if (q_rd >= q_wr) begin
                $display("FAIL: unexpected RX beat with no expected beat queued");
                failures = failures + 1;
            end else begin
                if (m_data !== exp_data[q_rd]) begin
                    $display("FAIL: data mismatch beat %0d", q_rd);
                    failures = failures + 1;
                end
                if (m_keep !== exp_keep[q_rd]) begin
                    $display("FAIL: TKEEP mismatch beat %0d got=%h exp=%h", q_rd, m_keep, exp_keep[q_rd]);
                    failures = failures + 1;
                end
                if (m_last !== exp_last[q_rd]) begin
                    $display("FAIL: TLAST mismatch beat %0d got=%b exp=%b", q_rd, m_last, exp_last[q_rd]);
                    failures = failures + 1;
                end
                beat_checks = beat_checks + 1;
            end
            q_rd = q_rd + 1;
        end
        if (rst_n && rx_error) begin
            error_pulses = error_pulses + 1;
            $display("RX error pulse code=%0d", rx_error_code);
        end
    end

    task automatic send_beat;
        input integer source;
        input [511:0] data;
        input [63:0] keep;
        input last;
        input track_expected;
        integer k;
        reg [511:0] normalized;
        begin
            @(negedge clk);
            if (source == 0) begin
                s0_data = data; s0_keep = keep; s0_last = last; s0_valid = 1'b1;
            end else begin
                s1_data = data; s1_keep = keep; s1_last = last; s1_valid = 1'b1;
            end

            if (track_expected) begin
                normalized = 512'd0;
                for (k = 0; k < 64; k = k + 1)
                    normalized[k*8 +: 8] = keep[k] ? data[k*8 +: 8] : 8'h00;
                exp_data[q_wr] = normalized;
                exp_keep[q_wr] = keep;
                exp_last[q_wr] = last;
                q_wr = q_wr + 1;
            end

            if (source == 0) begin
                do @(posedge clk); while (s0_ready !== 1'b1);
            end else begin
                do @(posedge clk); while (s1_ready !== 1'b1);
            end
            @(negedge clk);
            if (source == 0) begin s0_valid = 1'b0; s0_last = 1'b0; end
            else begin s1_valid = 1'b0; s1_last = 1'b0; end
        end
    endtask

    task automatic wait_for_expected_drain;
        integer watchdog;
        begin
            watchdog = 0;
            while ((q_rd < q_wr) && watchdog < 2000) begin
                @(posedge clk);
                watchdog = watchdog + 1;
            end
            if (q_rd != q_wr) begin
                $display("FAIL: timeout waiting for RX. expected=%0d received=%0d", q_wr, q_rd);
                failures = failures + 1;
            end
            repeat (12) @(posedge clk);
        end
    endtask

    initial begin : test_main
        integer i;
        reg [511:0] pattern;
        $dumpfile("sim/dump_top_4layer_bidir.vcd");
        $dumpvars(0, tb_top_4layer_bidir);

        repeat (5) @(posedge clk);
        @(negedge clk); rst_n = 1'b1;
        repeat (3) @(posedge clk);

        // Packet A: two beats, early TLAST on beat 1, sparse byte masks.
        send_beat(0, {8{64'h0123456789ABCDEF}}, 64'hF00FF00F55AA55AA, 1'b0, 1'b1);
        send_beat(0, 512'hFEDCBA9876543210FEDCBA9876543210FEDCBA9876543210FEDCBA9876543210FEDCBA9876543210FEDCBA9876543210FEDCBA9876543210FEDCBA9876543210, 64'h000000000000FFFF, 1'b1, 1'b1);

        // Packet B: single beat from the second master.
        send_beat(1, 512'h112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF00, 64'h000000000000001F, 1'b1, 1'b1);

        // Packet C: five beats, so it crosses a four-beat FLIT boundary.
        for (i = 0; i < 5; i = i + 1) begin
            pattern = {8{64'hA500000000000000}} ^ (i + 32'h1234);
            send_beat(0, pattern, (i == 4) ? 64'h0000000000FFFFFF : 64'hFFFFFFFFFFFFFFFF,
                      (i == 4), 1'b1);
        end

        // Packet D: exactly one full FLIT; TLAST accompanies beat 3.
        for (i = 0; i < 4; i = i + 1) begin
            pattern = {8{64'hB600000000000000}} ^ (i + 32'h5678);
            send_beat(1, pattern, {64{1'b1}}, (i == 3), 1'b1);
        end

        wait_for_expected_drain();
        if (q_wr != 12) begin
            $display("FAIL: testbench expected 12 valid beats, queued %0d", q_wr);
            failures = failures + 1;
        end
        if (beat_checks != q_wr) begin
            $display("FAIL: checked beat count %0d != expected %0d", beat_checks, q_wr);
            failures = failures + 1;
        end
        if (rx_good_frames < 5) begin
            $display("FAIL: expected at least 5 valid frames before corruption, got %0d", rx_good_frames);
            failures = failures + 1;
        end

        // Corrupt only the first data symbol of the next TX frame. RX must
        // report CRC failure and must not release this packet to AXI output.
        @(negedge clk); corrupt_enable = 1'b1;
        send_beat(1, 512'hDEADBEEF12345678, 64'hFFFFFFFFFFFFFFFF, 1'b1, 1'b0);
        wait (tx_lane_valid && tx_lane_ready);
        @(posedge clk);
        @(negedge clk); corrupt_enable = 1'b0;
        begin : wait_bad
            integer watchdog;
            watchdog = 0;
            while ((rx_bad_frames == 0) && watchdog < 1000) begin
                @(posedge clk); watchdog = watchdog + 1;
            end
            if (rx_bad_frames != 1) begin
                $display("FAIL: corrupt frame was not rejected (bad count=%0d)", rx_bad_frames);
                failures = failures + 1;
            end
        end
        repeat (8) @(posedge clk);
        if (q_rd != q_wr) begin
            $display("FAIL: corrupted packet unexpectedly affected expected queue: rd=%0d wr=%0d", q_rd, q_wr);
            failures = failures + 1;
        end

        // A clean packet after the CRC error proves the receiver recovered.
        send_beat(0, 512'hCAFECAFE0123456789, 64'h00000000000003FF, 1'b1, 1'b1);
        wait_for_expected_drain();

        if (rx_bad_frames != 1) begin
            $display("FAIL: expected exactly one rejected frame, got %0d", rx_bad_frames);
            failures = failures + 1;
        end
        if (rx_good_frames < 6) begin
            $display("FAIL: expected recovery valid frame, good count=%0d", rx_good_frames);
            failures = failures + 1;
        end

        if (failures == 0) begin
            $display("PASS: BIDIR loopback; beats=%0d frames_ok=%0d frames_bad=%0d checks=%0d",
                     beat_checks, rx_good_frames, rx_bad_frames, beat_checks*3);
        end else begin
            $display("FAIL: BIDIR loopback failures=%0d", failures);
        end
        $display("BIDIR_TEST_SUMMARY expected_beats=%0d observed_beats=%0d good_frames=%0d bad_frames=%0d error_pulses=%0d failures=%0d",
                 q_wr, q_rd, rx_good_frames, rx_bad_frames, error_pulses, failures);
        if (failures != 0) $fatal(1, "Bidirectional link regression failed");
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "Global simulation timeout");
    end
endmodule
