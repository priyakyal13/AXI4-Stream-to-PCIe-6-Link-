`timescale 1ns/1ps
// Randomised self-checking testbench for layer3_flit_packetizer.
// Stimulus + expected results come from scripts/gen_rand_l3.py (zlib CRC golden model).
// Random input gaps and random output stalls.  Run: make random SEED=3 N=1000
module tb_rand_layer3;
    `include "rand_params.vh"          // NBEATS, NFLITS

    integer MAXGAP = 3;                // +gap=N   : 0..N idle cycles between input beats
    integer STALL_PCT = 40;            // +stall=P : % of cycles output ready is low
    integer t_start = 0, t_end = 0;

    reg clk = 0, rst_n = 0;
    reg  [511:0] s_axis_tdata;
    reg  [63:0]  s_axis_tkeep;
    reg          s_axis_tvalid, s_axis_tlast;
    wire         s_axis_tready;
    wire [2047:0] m_flit_data;
    wire [31:0]   m_flit_crc;
    wire          m_flit_valid, m_flit_partial;
    reg           m_flit_ready;

    layer3_flit_packetizer dut (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(s_axis_tdata), .s_axis_tkeep(s_axis_tkeep),
        .s_axis_tvalid(s_axis_tvalid), .s_axis_tready(s_axis_tready), .s_axis_tlast(s_axis_tlast),
        .m_flit_data(m_flit_data), .m_flit_crc(m_flit_crc),
        .m_flit_valid(m_flit_valid), .m_flit_ready(m_flit_ready), .m_flit_partial(m_flit_partial),
        .m_flit_tkeep(), .m_flit_tlasts(), .m_flit_beat_valid()
    );
    always #5 clk = ~clk;

    reg [511:0]  st_data [0:NBEATS-1];
    reg [63:0]   st_keep [0:NBEATS-1];
    reg          st_last [0:NBEATS-1];
    reg [2047:0] ex_data [0:NFLITS-1];
    reg [31:0]   ex_crc  [0:NFLITS-1];
    reg          ex_part [0:NFLITS-1];

    integer seed;
    integer pass_count = 0, fail_count = 0;
    integer fl_cnt = 0;
    integer i, n;

    function integer rnd(input integer max);   // 0 .. max-1
        begin rnd = $unsigned($random(seed)) % max; end
    endfunction

    initial begin
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        if (!$value$plusargs("gap=%d", MAXGAP)) MAXGAP = 3;
        if (!$value$plusargs("stall=%d", STALL_PCT)) STALL_PCT = 40;
        $readmemh("sim/rand_stim_data.hex", st_data);
        $readmemh("sim/rand_stim_keep.hex", st_keep);
        $readmemh("sim/rand_stim_last.hex", st_last);
        $readmemh("sim/rand_exp_data.hex",  ex_data);
        $readmemh("sim/rand_exp_crc.hex",   ex_crc);
        $readmemh("sim/rand_exp_part.hex",  ex_part);
    end

    // ---------------- random output ready ----------------
    always @(negedge clk) m_flit_ready = (rnd(100) >= STALL_PCT);

    // ---------------- output checker ----------------
    reg          stalled = 0;
    reg [2047:0] hold_data;
    reg [31:0]   hold_crc;
    reg          hold_part;
    always @(posedge clk) if (rst_n) begin
        // stability: once valid is shown while stalled, outputs must not change
        if (stalled) begin
            if (m_flit_valid !== 1'b1 || m_flit_data !== hold_data ||
                m_flit_crc !== hold_crc || m_flit_partial !== hold_part) begin
                fail_count = fail_count + 1;
                $display("FAIL: outputs changed/dropped while stalled (flit %0d)", fl_cnt);
            end else pass_count = pass_count + 1;
        end
        if (m_flit_valid && !m_flit_ready) begin
            stalled = 1; hold_data = m_flit_data; hold_crc = m_flit_crc; hold_part = m_flit_partial;
        end else stalled = 0;

        if (m_flit_valid && m_flit_ready) begin
            if (fl_cnt >= NFLITS) begin
                fail_count = fail_count + 1;
                $display("FAIL: unexpected extra FLIT #%0d", fl_cnt);
            end else begin
                if (m_flit_data === ex_data[fl_cnt]) pass_count = pass_count + 1;
                else begin fail_count = fail_count + 1; $display("FAIL: FLIT %0d data mismatch", fl_cnt); end
                if (m_flit_crc === ex_crc[fl_cnt]) pass_count = pass_count + 1;
                else begin fail_count = fail_count + 1;
                    $display("FAIL: FLIT %0d CRC got=%08h exp=%08h", fl_cnt, m_flit_crc, ex_crc[fl_cnt]); end
                if (m_flit_partial === ex_part[fl_cnt]) pass_count = pass_count + 1;
                else begin fail_count = fail_count + 1; $display("FAIL: FLIT %0d partial flag", fl_cnt); end
            end
            fl_cnt = fl_cnt + 1;
            if (fl_cnt == NFLITS) t_end = $time;
        end
    end

    // ---------------- stimulus ----------------
    initial begin
        s_axis_tvalid = 0; s_axis_tlast = 0; s_axis_tdata = 0; s_axis_tkeep = 0; m_flit_ready = 1;
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(negedge clk);
        for (i = 0; i < NBEATS; i = i + 1) begin
            n = rnd(MAXGAP + 1);
            repeat (n) @(negedge clk);                 // 0 => back-to-back
            s_axis_tdata  = st_data[i];
            s_axis_tkeep  = st_keep[i];
            s_axis_tlast  = st_last[i];
            s_axis_tvalid = 1;
            if (i == 0) t_start = $time;
            @(posedge clk);
            while (s_axis_tready !== 1'b1) @(posedge clk);   // accepted at this edge
            @(negedge clk);
            s_axis_tvalid = 0; s_axis_tlast = 0;
        end
        // drain
        n = 0;
        while (fl_cnt < NFLITS && n < 200000) begin @(posedge clk); n = n + 1; end
        repeat (50) @(posedge clk);                    // catch any extra FLIT
        if (fl_cnt !== NFLITS) begin
            fail_count = fail_count + 1;
            $display("FAIL: expected %0d FLITs, saw %0d", NFLITS, fl_cnt);
        end
        $display("random run: seed=%0d beats=%0d flits=%0d gap<=%0d stall=%0d%%", seed, NBEATS, fl_cnt, MAXGAP, STALL_PCT);
        if (t_end > t_start)
            $display("THROUGHPUT: %0d cycles, %0f beats/cycle, %0f FLITs/cycle (4 cycles/FLIT = 0.25 is the ideal for full FLITs)",
                     (t_end - t_start)/10, (1.0*NBEATS*10)/(t_end - t_start), (1.0*NFLITS*10)/(t_end - t_start));
        $display("TESTS PASSED: %0d TESTS FAILED: %0d", pass_count, fail_count);
        if (fail_count == 0) $display("RESULT: ALL TESTS PASSED");
        else                 $display("RESULT: FAILURES PRESENT");
        $finish;
    end
endmodule
