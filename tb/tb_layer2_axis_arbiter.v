`timescale 1ns/1ps

// =============================================================
// tb_layer2_axis_arbiter.v
//
// Standalone verification of layer2_axis_arbiter (Layer 2).
//
// Test philosophy: for the contended/concurrent scenario (Test 3)
// this TB deliberately checks STRUCTURAL, timing-insensitive
// properties (no dropped/duplicated beats, no starvation, packet
// atomicity via a whitebox invariant on the DUT's internal
// locked/grant state) rather than asserting one specific exact
// interleave ordering. Hand-verifying an exact cycle-by-cycle
// interleave of two concurrent AXI-Stream drivers without being
// able to run the simulator myself is exactly the kind of thing
// that produces a testbench which is wrong instead of a DUT that
// is wrong — so scenarios 1/2/4/5 (single driver, fully
// deterministic) get exact sequence checks, and scenario 3 (two
// concurrent drivers) gets robust property checks instead.
// =============================================================

module tb_layer2_axis_arbiter;

    localparam TDATA_WIDTH = 512;
    localparam CLK_PERIOD  = 10;

    reg clk, rst_n;

    reg  [TDATA_WIDTH-1:0]     s_axis0_tdata;
    reg  [(TDATA_WIDTH/8)-1:0] s_axis0_tkeep;
    reg                        s_axis0_tvalid;
    wire                       s_axis0_tready;
    reg                        s_axis0_tlast;

    reg  [TDATA_WIDTH-1:0]     s_axis1_tdata;
    reg  [(TDATA_WIDTH/8)-1:0] s_axis1_tkeep;
    reg                        s_axis1_tvalid;
    wire                       s_axis1_tready;
    reg                        s_axis1_tlast;

    wire [TDATA_WIDTH-1:0]     m_axis_tdata;
    wire [(TDATA_WIDTH/8)-1:0] m_axis_tkeep;
    wire                       m_axis_tvalid;
    reg                        m_axis_tready;
    wire                       m_axis_tlast;

    wire [31:0] dbg_grant0_count, dbg_grant1_count;

    integer pass_count = 0;
    integer fail_count = 0;

    layer2_axis_arbiter #(.TDATA_WIDTH(TDATA_WIDTH)) dut (
        .clk(clk), .rst_n(rst_n),
        .s_axis0_tdata(s_axis0_tdata), .s_axis0_tkeep(s_axis0_tkeep),
        .s_axis0_tvalid(s_axis0_tvalid), .s_axis0_tready(s_axis0_tready), .s_axis0_tlast(s_axis0_tlast),
        .s_axis1_tdata(s_axis1_tdata), .s_axis1_tkeep(s_axis1_tkeep),
        .s_axis1_tvalid(s_axis1_tvalid), .s_axis1_tready(s_axis1_tready), .s_axis1_tlast(s_axis1_tlast),
        .m_axis_tdata(m_axis_tdata), .m_axis_tkeep(m_axis_tkeep),
        .m_axis_tvalid(m_axis_tvalid), .m_axis_tready(m_axis_tready), .m_axis_tlast(m_axis_tlast),
        .dbg_grant0_count(dbg_grant0_count), .dbg_grant1_count(dbg_grant1_count)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    // ---------------- passive receive log (order of accepted output beats) ----------------
    reg [TDATA_WIDTH-1:0] rx_data [0:255];
    reg                    rx_last [0:255];
    integer rx_count = 0;

    always @(posedge clk) begin
        if (m_axis_tvalid && m_axis_tready) begin
            rx_data[rx_count] <= m_axis_tdata;
            rx_last[rx_count] <= m_axis_tlast;
            rx_count          <= rx_count + 1;
        end
    end

    // ---------------- whitebox atomicity invariant ----------------
    // While the DUT is locked onto one master, the OTHER master must
    // never be granted (tready==1). Structurally guaranteed by the
    // mux, but checked at runtime as a regression net.
    integer atomicity_violations = 0;
    always @(posedge clk) begin
        if (dut.locked) begin
            if (dut.grant == 1'b0 && s_axis1_tready === 1'b1)
                atomicity_violations = atomicity_violations + 1;
            if (dut.grant == 1'b1 && s_axis0_tready === 1'b1)
                atomicity_violations = atomicity_violations + 1;
        end
    end

    task reset_dut;
        begin
            rst_n = 0;
            s_axis0_tvalid = 0; s_axis0_tlast = 0; s_axis0_tdata = 0; s_axis0_tkeep = {(TDATA_WIDTH/8){1'b1}};
            s_axis1_tvalid = 0; s_axis1_tlast = 0; s_axis1_tdata = 0; s_axis1_tkeep = {(TDATA_WIDTH/8){1'b1}};
            m_axis_tready  = 1;
            repeat (3) @(posedge clk);
            rst_n = 1;
            @(posedge clk);
        end
    endtask

    task drive0(input [TDATA_WIDTH-1:0] data, input last);
        begin
            @(negedge clk);
            s_axis0_tdata  = data;
            s_axis0_tkeep  = {(TDATA_WIDTH/8){1'b1}};
            s_axis0_tvalid = 1;
            s_axis0_tlast  = last;
            @(posedge clk);
            while (s_axis0_tready !== 1'b1) @(posedge clk);
            @(negedge clk);
            s_axis0_tvalid = 0;
            s_axis0_tlast  = 0;
        end
    endtask

    task drive1(input [TDATA_WIDTH-1:0] data, input last);
        begin
            @(negedge clk);
            s_axis1_tdata  = data;
            s_axis1_tkeep  = {(TDATA_WIDTH/8){1'b1}};
            s_axis1_tvalid = 1;
            s_axis1_tlast  = last;
            @(posedge clk);
            while (s_axis1_tready !== 1'b1) @(posedge clk);
            @(negedge clk);
            s_axis1_tvalid = 0;
            s_axis1_tlast  = 0;
        end
    endtask

    integer exp_idx = 0;
    task check_next_beat(input [TDATA_WIDTH-1:0] exp_data, input exp_last, input [255:0] label);
        begin
            while (rx_count <= exp_idx) @(posedge clk);
            @(negedge clk);
            if (rx_data[exp_idx] === exp_data && rx_last[exp_idx] === exp_last)
                pass_count = pass_count + 1;
            else begin
                fail_count = fail_count + 1;
                $display("FAIL [%0s]: beat %0d mismatch. got last=%b exp last=%b",
                          label, exp_idx, rx_last[exp_idx], exp_last);
            end
            exp_idx = exp_idx + 1;
        end
    endtask

    initial begin
        clk = 0;
        reset_dut;

        // -------- Test 1: master0 alone, 3-beat packet --------
        drive0({16{32'hAAAA_0001}}, 0);
        drive0({16{32'hAAAA_0002}}, 0);
        drive0({16{32'hAAAA_0003}}, 1);
        check_next_beat({16{32'hAAAA_0001}}, 1'b0, "m0_alone_beat0");
        check_next_beat({16{32'hAAAA_0002}}, 1'b0, "m0_alone_beat1");
        check_next_beat({16{32'hAAAA_0003}}, 1'b1, "m0_alone_beat2");

        // -------- Test 2: master1 alone, 2-beat packet --------
        drive1({16{32'hBBBB_0001}}, 0);
        drive1({16{32'hBBBB_0002}}, 1);
        check_next_beat({16{32'hBBBB_0001}}, 1'b0, "m1_alone_beat0");
        check_next_beat({16{32'hBBBB_0002}}, 1'b1, "m1_alone_beat1");

        // -------- Test 3: sustained contention, both masters continuously
        //                  requesting 3 packets of 2 beats each. Robust
        //                  property checks only (see file header). --------
        begin : contention_test
            integer rx_before, grants0_before, grants1_before;
            integer i, last_count, k;
            rx_before      = rx_count;
            grants0_before = dbg_grant0_count;
            grants1_before = dbg_grant1_count;

            fork
                begin : m0_burst
                    integer p;
                    for (p = 0; p < 3; p = p + 1) begin
drive0({16{32'hC000_0000 + (p * 32'd2)}},   1'b0);
drive0({16{32'hC000_0000 + (p * 32'd2 + 32'd1)}}, 1'b1);
                                            end
                end
                begin : m1_burst
                    integer p;
                    for (p = 0; p < 3; p = p + 1) begin
                        drive1({16{32'hD000_0000 + (p * 32'd2)}},   1'b0);
drive1({16{32'hD000_0000 + (p * 32'd2 + 32'd1)}}, 1'b1);                    end
                end
            join

            // Property 1: exactly 12 beats received (6 packets x 2 beats),
            // no drops, no duplicates.
            if ((rx_count - rx_before) == 12) pass_count = pass_count + 1;
            else begin
                fail_count = fail_count + 1;
                $display("FAIL [contention]: expected 12 beats, got %0d", rx_count - rx_before);
            end

            // Property 2: no starvation — each master's 3 packets were
            // actually granted (conservation of grant counts).
            if ((dbg_grant0_count - grants0_before) == 3) pass_count = pass_count + 1;
            else begin fail_count = fail_count + 1; $display("FAIL [contention]: master0 grant count wrong"); end

            if ((dbg_grant1_count - grants1_before) == 3) pass_count = pass_count + 1;
            else begin fail_count = fail_count + 1; $display("FAIL [contention]: master1 grant count wrong"); end

            // Property 3: structural atomicity — every packet is exactly
            // 2 beats (last=0 then last=1), never broken/interleaved.
            // Walk the received log in pairs and check the pattern holds.
            last_count = 0;
            for (k = rx_before; k < rx_count; k = k + 1)
                if (rx_last[k]) last_count = last_count + 1;
            if (last_count == 6) pass_count = pass_count + 1;
            else begin fail_count = fail_count + 1; $display("FAIL [contention]: expected 6 last-beats, got %0d", last_count); end

            for (k = rx_before; k < rx_count; k = k + 2) begin
                if (rx_last[k] === 1'b0 && rx_last[k+1] === 1'b1) pass_count = pass_count + 1;
                else begin
                    fail_count = fail_count + 1;
                    $display("FAIL [contention]: packet framing broken at log index %0d", k);
                end
            end

            // Property 4: SOURCE-ATTRIBUTION SCOREBOARD. Properties 1-3
            // only prove nothing was obviously lost/duplicated and packet
            // framing held — they do not prove a received beat's DATA
            // actually came from the master it's attributed to, or that
            // a master's own packets emerged in the order it sent them.
            // Each master's beats are tagged (0xC0.. for master0, 0xD0..
            // for master1) with a per-packet counter baked into the data
            // itself, so we can classify each received beat by its tag
            // and check it against that master's own expected sequence,
            // in order, independent of how the two masters interleaved.
            begin : source_scoreboard
                reg [TDATA_WIDTH-1:0] m0_exp [0:5];
                reg [TDATA_WIDTH-1:0] m1_exp [0:5];
                integer m0_next, m1_next;
                integer p2;
                reg [15:0] tag;

                for (p2 = 0; p2 < 6; p2 = p2 + 1) begin
                    m0_exp[p2] = {16{32'hC000_0000 + p2}};
                    m1_exp[p2] = {16{32'hD000_0000 + p2}};
                end
                m0_next = 0;
                m1_next = 0;

                for (k = rx_before; k < rx_count; k = k + 1) begin
                    tag = rx_data[k][31:16];
                    if (tag == 16'hC000) begin
                        if (m0_next < 6 && rx_data[k] === m0_exp[m0_next])
                            pass_count = pass_count + 1;
                        else begin
                            fail_count = fail_count + 1;
                            $display("FAIL [scoreboard]: master0 beat out of order/corrupted at log idx %0d (expected seq %0d)", k, m0_next);
                        end
                        m0_next = m0_next + 1;
                    end else if (tag == 16'hD000) begin
                        if (m1_next < 6 && rx_data[k] === m1_exp[m1_next])
                            pass_count = pass_count + 1;
                        else begin
                            fail_count = fail_count + 1;
                            $display("FAIL [scoreboard]: master1 beat out of order/corrupted at log idx %0d (expected seq %0d)", k, m1_next);
                        end
                        m1_next = m1_next + 1;
                    end else begin
                        fail_count = fail_count + 1;
                        $display("FAIL [scoreboard]: unrecognized source tag %h at log idx %0d", tag, k);
                    end
                end

                if (m0_next == 6) pass_count = pass_count + 1;
                else begin fail_count = fail_count + 1; $display("FAIL [scoreboard]: master0 beat count wrong, got %0d", m0_next); end

                if (m1_next == 6) pass_count = pass_count + 1;
                else begin fail_count = fail_count + 1; $display("FAIL [scoreboard]: master1 beat count wrong, got %0d", m1_next); end
            end

            // Test 3 only used property checks above (rx_before/rx_count),
            // never advancing exp_idx even though 12 real entries were
            // appended to the log. Resync the check_next_beat cursor here
            // so Test 4/5 read the correct log positions instead of
            // silently re-reading Test 3's entries.
            exp_idx = rx_count;
        end

        // -------- Test 4: backpressure mid-packet --------
        // Hold m_axis_tready low for a few cycles between beat0 and beat1
        // of a 2-beat master0 packet.
        fork
            begin
                drive0({16{32'hE111_1111}}, 0);
                drive0({16{32'hE222_2222}}, 1);
            end
            begin
                @(posedge clk);
                while (!(m_axis_tvalid && m_axis_tready)) @(posedge clk); // wait for beat0 accepted
                @(negedge clk);
                m_axis_tready = 0;
                repeat (4) @(posedge clk);
                @(negedge clk);
                m_axis_tready = 1;
            end
        join
        check_next_beat({16{32'hE111_1111}}, 1'b0, "backpressure_beat0");
        check_next_beat({16{32'hE222_2222}}, 1'b1, "backpressure_beat1");

        // -------- Test 5: reset mid-packet, then confirm clean recovery --------
        @(negedge clk);
        s_axis0_tdata  = {16{32'hFFFF_FFFF}};
        s_axis0_tkeep  = {(TDATA_WIDTH/8){1'b1}};
        s_axis0_tvalid = 1;
        s_axis0_tlast  = 0; // not last -> would normally lock the arbiter
        @(posedge clk);
        while (s_axis0_tready !== 1'b1) @(posedge clk);
        @(negedge clk);
        s_axis0_tvalid = 0;
        // This beat was already forwarded (the arbiter passes each beat
        // through immediately, unlike the FLIT layer which buffers a
        // whole packet) — it landed in the log even though we're about
        // to reset. Skip over it so check_next_beat doesn't misread it
        // as the post-reset recovery beat.
        exp_idx = rx_count;
        reset_dut; // resets locked/grant state mid-packet

        if (s_axis0_tready === 1'b0 && s_axis1_tready === 1'b0)
            pass_count = pass_count + 1; // idle, neither requesting yet -> both low
        else begin
            fail_count = fail_count + 1;
            $display("FAIL: tready lines not idle-low immediately post-reset with no requests");
        end

        // A fresh single-beat packet from master1 should go through cleanly,
        // proving the lock/grant state didn't get stuck from the aborted packet.
        drive1({16{32'h1234_5678}}, 1);
        check_next_beat({16{32'h1234_5678}}, 1'b1, "post_reset_recovery");

        $display("=================================================");
        $display("TESTS PASSED: %0d   TESTS FAILED: %0d", pass_count, fail_count);
        $display("Atomicity invariant violations: %0d", atomicity_violations);
        $display("=================================================");
        if (fail_count == 0 && atomicity_violations == 0)
            $display("RESULT: ALL TESTS PASSED");
        else
            $display("RESULT: FAILURES PRESENT");

        $finish;
    end

    initial begin
        $dumpfile("sim/dump_layer2_axis_arbiter.vcd");
        $dumpvars(0, tb_layer2_axis_arbiter);
    end

endmodule
