`timescale 1ns/1ps

module tb_layer1_axis_stream_ingress;

    localparam TDATA_WIDTH = 512;
    localparam CLK_PERIOD  = 10;

    reg clk, rst_n;
    reg  [TDATA_WIDTH-1:0]     s_tdata;
    reg  [(TDATA_WIDTH/8)-1:0] s_tkeep;
    reg                        s_tvalid;
    wire                       s_tready;
    reg                        s_tlast;

    wire [TDATA_WIDTH-1:0]     m_tdata;
    wire [(TDATA_WIDTH/8)-1:0] m_tkeep;
    wire                       m_tvalid;
    reg                        m_tready;
    wire                       m_tlast;

    integer pass_count = 0;
    integer fail_count = 0;

    layer1_axis_stream_ingress #(.TDATA_WIDTH(TDATA_WIDTH)) dut (
        .clk(clk), .rst_n(rst_n),
        .s_tdata(s_tdata), .s_tkeep(s_tkeep), .s_tvalid(s_tvalid), .s_tready(s_tready), .s_tlast(s_tlast),
        .m_tdata(m_tdata), .m_tkeep(m_tkeep), .m_tvalid(m_tvalid), .m_tready(m_tready), .m_tlast(m_tlast)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    // ---------------- passive receive log ----------------
    reg [TDATA_WIDTH-1:0]     rx_data [0:255];
    reg [(TDATA_WIDTH/8)-1:0] rx_keep [0:255];
    reg                        rx_last [0:255];
    integer rx_count = 0;

    always @(posedge clk) begin
        if (m_tvalid && m_tready) begin
            rx_data[rx_count] <= m_tdata;
            rx_keep[rx_count] <= m_tkeep;
            rx_last[rx_count] <= m_tlast;
            rx_count          <= rx_count + 1;
        end
    end

    task reset_dut;
        begin
            rst_n = 0;
            s_tvalid = 0; s_tlast = 0; s_tdata = 0; s_tkeep = {(TDATA_WIDTH/8){1'b1}};
            m_tready = 1;
            repeat (3) @(posedge clk);
            rst_n = 1;
            @(posedge clk);
        end
    endtask

    task send_beat(input [TDATA_WIDTH-1:0] data, input last);
        begin
            @(negedge clk);
            s_tdata  = data;
            s_tkeep  = {(TDATA_WIDTH/8){1'b1}};
            s_tvalid = 1;
            s_tlast  = last;
            @(posedge clk);
            while (s_tready !== 1'b1) @(posedge clk);
            @(negedge clk);
            s_tvalid = 0;
            s_tlast  = 0;
        end
    endtask

    integer exp_idx = 0;
    task check_next(input [TDATA_WIDTH-1:0] exp_data, input exp_last, input [255:0] label);
        begin
            while (rx_count <= exp_idx) @(posedge clk);
            @(negedge clk);
            if (rx_data[exp_idx] === exp_data && rx_last[exp_idx] === exp_last)
                pass_count = pass_count + 1;
            else begin
                fail_count = fail_count + 1;
                $display("FAIL [%0s]: beat %0d mismatch", label, exp_idx);
            end
            exp_idx = exp_idx + 1;
        end
    endtask

    initial begin
        clk = 0;
        reset_dut;

        // -------- Test 1: basic in-order passthrough, 4 beats --------
        send_beat({16{32'h1111_0000}}, 0);
        send_beat({16{32'h1111_0001}}, 0);
        send_beat({16{32'h1111_0002}}, 0);
        send_beat({16{32'h1111_0003}}, 1);
        check_next({16{32'h1111_0000}}, 1'b0, "basic_beat0");
        check_next({16{32'h1111_0001}}, 1'b0, "basic_beat1");
        check_next({16{32'h1111_0002}}, 1'b0, "basic_beat2");
        check_next({16{32'h1111_0003}}, 1'b1, "basic_beat3");

        // -------- Test 2: continuous back-to-back throughput (no gaps).
        //                  Drives tvalid high across all 8 beats without
        //                  ever dropping it, changing tdata every cycle,
        //                  proving s_tready = m_tready|!m_tvalid actually
        //                  delivers full throughput and not just
        //                  gapped/task-paced transfers. --------
        begin : burst_test
            integer i, rx_before;
            rx_before = rx_count;
            @(negedge clk);
            s_tvalid = 1;
            s_tkeep  = {(TDATA_WIDTH/8){1'b1}};
            for (i = 0; i < 8; i = i + 1) begin
                s_tdata = {16{32'h2222_0000 + i}};
                s_tlast = (i == 7);
                @(posedge clk);
                // m_tready held high throughout -> s_tready should read 1
                // every single cycle here (zero-bubble claim under test).
                if (s_tready === 1'b1) pass_count = pass_count + 1;
                else begin fail_count = fail_count + 1; $display("FAIL [burst]: s_tready dropped mid-burst at beat %0d", i); end
                @(negedge clk);
            end
            s_tvalid = 0;
            s_tlast  = 0;

            // Drain and check all 8 landed, in order, 1-cycle-delayed.
            for (i = 0; i < 8; i = i + 1)
                check_next({16{32'h2222_0000 + i}}, (i == 7), "burst_beat");

            if ((rx_count - rx_before) == 8) pass_count = pass_count + 1;
            else begin fail_count = fail_count + 1; $display("FAIL [burst]: expected 8 beats, got %0d", rx_count - rx_before); end
        end

        // -------- Test 3: backpressure — m_tready held low for several
        //                  cycles after a beat is buffered. Verifies
        //                  m_tdata/tvalid hold stable and s_tready
        //                  correctly drops (buffer full, no drain). --------
        begin : backpressure_test
            integer r;
            m_tready = 0;
            @(negedge clk);
            s_tdata  = {16{32'h3333_0000}};
            s_tkeep  = {(TDATA_WIDTH/8){1'b1}};
            s_tvalid = 1;
            s_tlast  = 1'b0;
            @(posedge clk); // beat accepted into the register (buffer was empty)
            @(negedge clk);
            s_tvalid = 0;

            @(posedge clk);
            while (!m_tvalid) @(posedge clk);

            for (r = 0; r < 4; r = r + 1) begin
                @(negedge clk);
                if (m_tvalid === 1'b1 && m_tdata === {16{32'h3333_0000}})
                    pass_count = pass_count + 1;
                else begin fail_count = fail_count + 1; $display("FAIL [backpressure]: output did not hold stable while stalled"); end
                if (s_tready === 1'b0) pass_count = pass_count + 1;
                else begin fail_count = fail_count + 1; $display("FAIL [backpressure]: s_tready should be low (buffer full, consumer stalled)"); end
            end

            @(negedge clk);
            m_tready = 1;
            check_next({16{32'h3333_0000}}, 1'b0, "backpressure_release");
        end

        // -------- Test 4: reset mid-transfer clears cleanly --------
        @(negedge clk);
        s_tdata  = {16{32'h4444_0000}};
        s_tkeep  = {(TDATA_WIDTH/8){1'b1}};
        s_tvalid = 1;
        s_tlast  = 0;
        @(posedge clk);
        while (s_tready !== 1'b1) @(posedge clk);
        @(negedge clk);
        s_tvalid = 0;
        reset_dut;
        if (m_tvalid === 1'b0 && s_tready === 1'b1) pass_count = pass_count + 1;
        else begin fail_count = fail_count + 1; $display("FAIL: state not clean after mid-transfer reset"); end

        // Confirm fresh traffic still works post-reset.
        send_beat({16{32'h5555_0000}}, 1'b1);
        check_next({16{32'h5555_0000}}, 1'b1, "post_reset_recovery");

        $display("=================================================");
        $display("TESTS PASSED: %0d   TESTS FAILED: %0d", pass_count, fail_count);
        $display("=================================================");
        if (fail_count == 0) $display("RESULT: ALL TESTS PASSED");
        else                 $display("RESULT: FAILURES PRESENT");

        $finish;
    end

    initial begin
        $dumpfile("sim/dump_layer1_axis_stream_ingress.vcd");
        $dumpvars(0, tb_layer1_axis_stream_ingress);
    end

endmodule
