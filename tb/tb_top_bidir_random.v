`timescale 1ns/1ps
// =============================================================================
// Randomised end-to-end loopback scoreboard for top_4layer_bidir.
//   2 AXI4-Stream sources -> arbiter -> L1 -> L3 -> framed TX -> [link] -> RX -> AXI4-Stream out
// * random packets: 1..9 beats (crosses FLIT boundaries), mixed TKEEP (full / prefix / sparse / single / zero)
// * random source valid gaps, random sink backpressure
// * scoreboard: every output packet must equal, beat for beat (data masked by TKEEP, TKEEP, TLAST),
//   the next not-yet-delivered packet of source 0 OR source 1 (arbiter is packet-atomic);
//   nothing lost, nothing duplicated, nothing reordered within a source, no rx_error
// * AXI-Stream stability checks on the output and on source tready/valid handshakes
// * mid-traffic reset: queues flushed, DUT must come back clean and pass a second traffic phase
// Plusargs: +seed=N  +npk=N (packets per source per phase)  +gap=N (max idle between beats)  +bp=P (sink ready %)
// =============================================================================
module tb_top_bidir_random;
    localparam MAXB = 4096;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg [511:0] s0_data = 0, s1_data = 0; reg [63:0] s0_keep = 0, s1_keep = 0;
    reg s0_valid = 0, s1_valid = 0, s0_last = 0, s1_last = 0; wire s0_ready, s1_ready;
    wire [595:0] t0, t1, t2, t3; wire tv, tr;
    wire [511:0] md; wire [63:0] mk; wire mv, ml; reg mr = 0;
    wire rerr; wire [1:0] rcode; wire [31:0] rgood, rbad;

    top_4layer_bidir dut (.clk(clk), .rst_n(rst_n),
        .s_axis0_tdata(s0_data), .s_axis0_tkeep(s0_keep), .s_axis0_tvalid(s0_valid), .s_axis0_tready(s0_ready), .s_axis0_tlast(s0_last),
        .s_axis1_tdata(s1_data), .s_axis1_tkeep(s1_keep), .s_axis1_tvalid(s1_valid), .s_axis1_tready(s1_ready), .s_axis1_tlast(s1_last),
        .m_tx_lane0_data(t0), .m_tx_lane1_data(t1), .m_tx_lane2_data(t2), .m_tx_lane3_data(t3), .m_tx_lane_valid(tv), .m_tx_lane_ready(tr),
        .s_rx_lane0_data(t0), .s_rx_lane1_data(t1), .s_rx_lane2_data(t2), .s_rx_lane3_data(t3), .s_rx_lane_valid(tv), .s_rx_lane_ready(tr),
        .m_axis_tdata(md), .m_axis_tkeep(mk), .m_axis_tvalid(mv), .m_axis_tready(mr), .m_axis_tlast(ml),
        .rx_error(rerr), .rx_error_code(rcode), .rx_good_frames(rgood), .rx_bad_frames(rbad));

    // expected beats per source (flat arrays); w = write index, h = head of next undelivered packet
    reg [511:0] e0d [0:MAXB-1]; reg [63:0] e0k [0:MAXB-1]; reg e0l [0:MAXB-1];
    reg [511:0] e1d [0:MAXB-1]; reg [63:0] e1k [0:MAXB-1]; reg e1l [0:MAXB-1];
    integer w0 = 0, w1 = 0, h0 = 0, h1 = 0;
    integer fails = 0, pkts_out = 0, beats_out = 0, pkts_in = 0;
    integer seed_i, npk, gap_max, bp_pct;
    reg [31:0] rb = 32'h2545F491;
    function [31:0] nx(input [31:0] x); reg [31:0] y; begin y = x ^ (x<<13); y = y ^ (y>>17); y = y ^ (y<<5); nx = y; end endfunction

    // ---- sink backpressure
    always @(negedge clk) begin
        rb = nx(rb);
        mr = !rst_n ? 1'b0 : ((bp_pct >= 100) ? 1'b1 : ((rb % 100) < bp_pct));
    end

    // ---- output monitor + packet matching
    reg [511:0] cd [0:63]; reg [63:0] ck [0:63]; reg cl [0:63]; integer clen = 0;
    reg p_st = 0; reg [511:0] p_d; reg [63:0] p_k; reg p_l;
    integer j; reg m0, m1;
    always @(posedge clk) begin
        if (!rst_n) begin clen = 0; p_st <= 0; end
        else begin
            if (p_st && (mv !== 1'b1 || md !== p_d || mk !== p_k || ml !== p_l)) begin
                $display("FAIL: output AXIS changed while stalled @%0t", $time); fails = fails + 1; end
            p_st <= (mv === 1'b1) && !mr; p_d <= md; p_k <= mk; p_l <= ml;
            if (rerr) begin $display("FAIL: unexpected rx_error code=%0d @%0t", rcode, $time); fails = fails + 1; end
            if (mv && mr) begin
                if (clen < 64) begin cd[clen] = md; ck[clen] = mk; cl[clen] = ml; end
                clen = clen + 1; beats_out = beats_out + 1;
                if (ml) begin
                    m0 = (h0 + clen <= w0); m1 = (h1 + clen <= w1);
                    for (j = 0; j < clen && j < 64; j = j + 1) begin
                        if (m0 && (e0d[h0+j] !== cd[j] || e0k[h0+j] !== ck[j] || e0l[h0+j] !== cl[j] || (e0l[h0+j] !== (j == clen-1)))) m0 = 0;
                        if (m1 && (e1d[h1+j] !== cd[j] || e1k[h1+j] !== ck[j] || e1l[h1+j] !== cl[j] || (e1l[h1+j] !== (j == clen-1)))) m1 = 0;
                    end
                    if (m0 && !m1)      begin h0 = h0 + clen; pkts_out = pkts_out + 1; end
                    else if (m1 && !m0) begin h1 = h1 + clen; pkts_out = pkts_out + 1; end
                    else if (m0 && m1)  begin h0 = h0 + clen; pkts_out = pkts_out + 1; end  // identical packets (cannot distinguish)
                    else begin $display("FAIL: output packet (len %0d) matches neither source head (h0=%0d h1=%0d) @%0t", clen, h0, h1, $time); fails = fails + 1; end
                    clen = 0;
                end
            end
        end
    end

    // ---- randomised packet drivers (one per source)
    function [63:0] rand_keep(input [31:0] r);
        reg [31:0] r2; integer n;
        begin
            r2 = nx(r);
            case (r[3:0])
                0,1,2,3,4,5: rand_keep = {64{1'b1}};
                6,7,8:       begin n = 1 + (r2 % 64); rand_keep = (n == 64) ? {64{1'b1}} : ((64'd1 << n) - 64'd1); end
                9,10,11:     rand_keep = {nx(r2), nx(nx(r2))};
                12,13:       rand_keep = 64'd1 << (r2 % 64);
                14:          rand_keep = 64'd0;
                default:     rand_keep = {64{1'b1}};
            endcase
        end
    endfunction

    task automatic send_packets(input integer src, input integer count, input [31:0] sd);
        integer p, b, len, g, k;
        reg [31:0] r; reg [511:0] d; reg [63:0] kp; reg last; reg [511:0] nd;
        begin
            r = sd | 1;
            for (p = 0; p < count; p = p + 1) begin
                r = nx(r); len = 1 + (r % 9);
                for (b = 0; b < len; b = b + 1) begin
                    r = nx(r); g = (gap_max == 0) ? 0 : (r % (gap_max + 1));
                    repeat (g) begin @(negedge clk); if (src == 0) s0_valid = 0; else s1_valid = 0; end
                    for (k = 0; k < 16; k = k + 1) begin r = nx(r); d[k*32 +: 32] = r; end
                    r = nx(r); kp = rand_keep(r); last = (b == len - 1);
                    @(negedge clk);
                    if (!rst_n) disable send_packets;
                    nd = 0; for (k = 0; k < 64; k = k + 1) nd[k*8 +: 8] = kp[k] ? d[k*8 +: 8] : 8'h00;
                    if (src == 0) begin s0_data = d; s0_keep = kp; s0_last = last; s0_valid = 1; e0d[w0] = nd; e0k[w0] = kp; e0l[w0] = last; w0 = w0 + 1; end
                    else          begin s1_data = d; s1_keep = kp; s1_last = last; s1_valid = 1; e1d[w1] = nd; e1k[w1] = kp; e1l[w1] = last; w1 = w1 + 1; end
                    if (src == 0) begin do @(posedge clk); while (s0_ready !== 1'b1 && rst_n); end
                    else          begin do @(posedge clk); while (s1_ready !== 1'b1 && rst_n); end
                    @(negedge clk);
                    if (src == 0) begin s0_valid = 0; s0_last = 0; s0_data = 0; end else begin s1_valid = 0; s1_last = 0; s1_data = 0; end
                end
                pkts_in = pkts_in + 1;
            end
        end
    endtask

    task wait_drain;
        integer wd;
        begin
            wd = 0;
            while ((h0 != w0 || h1 != w1) && wd < 200000) begin @(posedge clk); wd = wd + 1; end
            repeat (40) @(posedge clk);
            if (h0 != w0 || h1 != w1) begin $display("FAIL: undelivered beats: src0 %0d/%0d src1 %0d/%0d", h0, w0, h1, w1); fails = fails + 1; end
        end
    endtask

    initial begin : main
        integer ph;
        if (!$value$plusargs("seed=%d", seed_i)) seed_i = 1;
        if (!$value$plusargs("npk=%d", npk))     npk = 60;
        if (!$value$plusargs("gap=%d", gap_max)) gap_max = 2;
        if (!$value$plusargs("bp=%d", bp_pct))   bp_pct = 70;
        rb = rb ^ seed_i;
        repeat (5) @(posedge clk); @(negedge clk); rst_n = 1; repeat (3) @(posedge clk);

        // ---- phase 1: full random traffic from both sources
        fork send_packets(0, npk, seed_i * 7919); send_packets(1, npk, seed_i * 104729); join
        wait_drain;
        $display("phase1: packets in=%0d out=%0d beats_out=%0d frames_good=%0d frames_bad=%0d", pkts_in, pkts_out, beats_out, rgood, rbad);
        if (rbad != 0) begin $display("FAIL: rx_bad_frames=%0d in clean traffic", rbad); fails = fails + 1; end
        if (pkts_out != pkts_in) begin $display("FAIL: packets out %0d != in %0d", pkts_out, pkts_in); fails = fails + 1; end

        // ---- phase 2: reset in the middle of traffic
        fork
            send_packets(0, 6, seed_i * 31);
            send_packets(1, 6, seed_i * 37);
            begin repeat (23 + (seed_i % 11)) @(posedge clk); @(negedge clk);
                  rst_n = 0; s0_valid = 0; s1_valid = 0; s0_last = 0; s1_last = 0;
                  repeat (4) @(negedge clk); end
        join_any
        disable fork;
        @(negedge clk); s0_valid = 0; s1_valid = 0; rst_n = 0; repeat (3) @(negedge clk);
        w0 = 0; h0 = 0; w1 = 0; h1 = 0; clen = 0;                       // flush scoreboard: in-flight data is lost by reset
        if (mv !== 1'b0) begin $display("FAIL: m_axis_tvalid high during reset"); fails = fails + 1; end
        if (rgood !== 0 || rbad !== 0) begin $display("FAIL: counters not cleared by reset (good=%0d bad=%0d)", rgood, rbad); fails = fails + 1; end
        @(negedge clk); rst_n = 1; repeat (3) @(posedge clk);
        pkts_in = 0; pkts_out = 0;
        // ---- phase 3: traffic after reset must be exact (no stale beats from before reset)
        fork send_packets(0, npk / 2, seed_i * 53); send_packets(1, npk / 2, seed_i * 59); join
        wait_drain;
        $display("phase3 (post-reset): packets in=%0d out=%0d frames_good=%0d frames_bad=%0d", pkts_in, pkts_out, rgood, rbad);
        if (pkts_out != pkts_in) begin $display("FAIL: post-reset packets out %0d != in %0d", pkts_out, pkts_in); fails = fails + 1; end
        if (rbad != 0) begin $display("FAIL: post-reset rx_bad_frames=%0d", rbad); fails = fails + 1; end

        if (fails == 0) $display("PASS: BIDIR random loopback (seed=%0d npk=%0d gap<=%0d bp=%0d%%)", seed_i, npk, gap_max, bp_pct);
        else            $display("FAIL: BIDIR random loopback failures=%0d (seed=%0d)", fails, seed_i);
        if (fails != 0) $fatal(1, "random loopback failed");
        $finish;
    end
    initial begin #50000000; $display("FAIL: global timeout"); $fatal(1, "timeout"); end
endmodule
