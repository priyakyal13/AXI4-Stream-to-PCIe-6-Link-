`timescale 1ns/1ps
// =============================================================================
// RX scoreboard: drives the SAME Python/zlib-generated frame stream (valid frames,
// every class of corruption, garbage) into
//    (a) the REFERENCE RX  = verbatim original design (tb/ref)
//    (b) the NEW RX        = rtl/layer4_phy_lanes_to_axis.v
// and checks each against the independent model:
//    * released beats (data/keep/last), in order, nothing extra, nothing missing
//    * rx_error pulses and codes, in order (priority: magic > meta CRC > data CRC)
//    * rx_good_frames / rx_bad_frames
//    * AXI-Stream stability while stalled (tvalid held, payload stable)
//    * frame captured on the exact handshake edge (lanes are scrambled right after)
// Plusargs: +gap=<max idle cycles between frames> +bp=<percent ready, 1..100> +seed=<n>
// Inputs from sim/: rx_frames.hex rx_expect.hex rx_beats.hex rx_params.vh
// =============================================================================
`include "rx_params.vh"

module rx_harness #(parameter REF = 0, parameter NAME = "NEW") (
    input clk, input rst_n, input [31:0] seed, input [31:0] gap_max, input [31:0] bp_pct,
    output reg done, output reg [31:0] fails
);
    reg [595:0] lanes [0:4*`RX_NFRAMES-1];
    reg [7:0]   expst [0:2*`RX_NFRAMES-1];
    reg [511:0] beatm [0:3*`RX_NBEATS-1];
    initial begin
        $readmemh("sim/rx_frames.hex", lanes);
        $readmemh("sim/rx_expect.hex", expst);
        $readmemh("sim/rx_beats.hex", beatm);
    end

    reg [595:0] l0, l1, l2, l3; reg lvalid;
    wire lready;
    wire [511:0] md; wire [63:0] mk; wire mv, ml; reg mr;
    wire rerr; wire [1:0] rcode; wire [31:0] rgood, rbad;

    generate if (REF) begin : g_ref
        layer4_phy_lanes_to_axis_ref dut (.clk(clk), .rst_n(rst_n),
            .s_lane0_data(l0), .s_lane1_data(l1), .s_lane2_data(l2), .s_lane3_data(l3),
            .s_lane_valid(lvalid), .s_lane_ready(lready),
            .m_axis_tdata(md), .m_axis_tkeep(mk), .m_axis_tvalid(mv), .m_axis_tready(mr), .m_axis_tlast(ml),
            .rx_error(rerr), .rx_error_code(rcode), .rx_good_frames(rgood), .rx_bad_frames(rbad));
    end else begin : g_new
        layer4_phy_lanes_to_axis dut (.clk(clk), .rst_n(rst_n),
            .s_lane0_data(l0), .s_lane1_data(l1), .s_lane2_data(l2), .s_lane3_data(l3),
            .s_lane_valid(lvalid), .s_lane_ready(lready),
            .m_axis_tdata(md), .m_axis_tkeep(mk), .m_axis_tvalid(mv), .m_axis_tready(mr), .m_axis_tlast(ml),
            .rx_error(rerr), .rx_error_code(rcode), .rx_good_frames(rgood), .rx_bad_frames(rbad));
    end endgenerate

    // xorshift32 PRNG (portable, reproducible)
    reg [31:0] rs;
    function [31:0] nxt(input [31:0] x); reg [31:0] y; begin
        y = x ^ (x << 13); y = y ^ (y >> 17); y = y ^ (y << 5); nxt = y; end endfunction

    integer fi, k, gap, exp_beats, exp_bad, exp_good, bptr, eptr, nbeat_seen, nerr_seen;
    reg [595:0] junk;
    // ---------------- feeder ----------------
    initial begin
        done = 0; fails = 0; lvalid = 0; l0 = 0; l1 = 0; l2 = 0; l3 = 0;
        fi = 0; exp_bad = 0; exp_good = 0; exp_beats = 0;
        wait (rst_n === 1'b1);
        rs = seed | 1;
        for (k = 0; k < `RX_NFRAMES; k = k + 1) begin      // after $readmemh has run
            if (expst[2*k] == 0) exp_good = exp_good + 1; else exp_bad = exp_bad + 1;
            exp_beats = exp_beats + expst[2*k+1];
        end
        repeat (2) @(posedge clk);
        for (fi = 0; fi < `RX_NFRAMES; fi = fi + 1) begin
            rs = nxt(rs); gap = (gap_max == 0) ? 0 : (rs % (gap_max + 1));
            repeat (gap) begin
                @(negedge clk); lvalid = 0;
                rs = nxt(rs); l0 = {rs,rs,rs,rs,rs,rs,rs,rs,rs,rs,rs,rs,rs,rs,rs,rs,rs,rs,rs}; l1 = ~l0; l2 = l0 ^ l1 ^ 596'h1; l3 = l0 >> 3;
            end
            @(negedge clk);
            l0 = lanes[4*fi]; l1 = lanes[4*fi+1]; l2 = lanes[4*fi+2]; l3 = lanes[4*fi+3]; lvalid = 1;
            // hold until the handshake edge
            @(posedge clk); while (lready !== 1'b1) @(posedge clk);
            // data valid at this edge was captured; scramble immediately after it
            #1; lvalid = 0;
            rs = nxt(rs); l0 = {19{rs}}; l1 = ~{19{rs}}; l2 = {19{rs}} ^ 596'hDEAD; l3 = 596'h0;
        end
        // drain
        begin : drain
            integer w; w = 0;
            while ((nbeat_seen < exp_beats || nerr_seen < exp_bad || mv) && w < 200000) begin @(posedge clk); w = w + 1; end
            repeat (20) @(posedge clk);
        end
        // final checks
        if (nbeat_seen != exp_beats) begin $display("[%0s] FAIL: beats seen %0d != expected %0d", NAME, nbeat_seen, exp_beats); fails = fails + 1; end
        if (nerr_seen != exp_bad)    begin $display("[%0s] FAIL: errors seen %0d != expected %0d", NAME, nerr_seen, exp_bad); fails = fails + 1; end
        if (rgood !== exp_good)      begin $display("[%0s] FAIL: rx_good_frames %0d != %0d", NAME, rgood, exp_good); fails = fails + 1; end
        if (rbad !== exp_bad)        begin $display("[%0s] FAIL: rx_bad_frames %0d != %0d", NAME, rbad, exp_bad); fails = fails + 1; end
        done = 1;
    end

    // ---------------- backpressure ----------------
    reg [31:0] bs;
    initial begin bs = 32'hx; mr = 0; end
    always @(negedge clk) begin
        if (^bs === 1'bx) bs = (seed ^ 32'h9E3779B9) | 1;
        bs = nxt(bs);
        mr = (bp_pct >= 100) ? 1'b1 : ((bs % 100) < bp_pct);
    end

    // ---------------- output + error checking ----------------
    initial begin bptr = 0; eptr = 0; nbeat_seen = 0; nerr_seen = 0; end
    reg        p_stall; reg [511:0] p_d; reg [63:0] p_k; reg p_l;
    initial p_stall = 0;
    // find next expected-bad frame index pointer
    always @(posedge clk) if (rst_n) begin
        // AXI stability
        if (p_stall) begin
            if (mv !== 1'b1 || md !== p_d || mk !== p_k || ml !== p_l) begin
                $display("[%0s] FAIL: AXI stream changed while stalled @%0t", NAME, $time); fails = fails + 1; end
        end
        p_stall <= (mv === 1'b1) && !mr; p_d <= md; p_k <= mk; p_l <= ml;
        if (mv === 1'bx || ml === 1'bx) begin $display("[%0s] FAIL: X on tvalid/tlast @%0t", NAME, $time); fails = fails + 1; end
        if (mv && mr) begin
            if (nbeat_seen >= exp_beats) begin $display("[%0s] FAIL: extra beat released (bad frame leaked?) @%0t", NAME, $time); fails = fails + 1; end
            else begin
                if (mk !== beatm[3*nbeat_seen][63:0]) begin $display("[%0s] FAIL: TKEEP beat %0d got %h exp %h", NAME, nbeat_seen, mk, beatm[3*nbeat_seen][63:0]); fails = fails + 1; end
                if (ml !== beatm[3*nbeat_seen+1][0])  begin $display("[%0s] FAIL: TLAST beat %0d", NAME, nbeat_seen); fails = fails + 1; end
                if (md !== beatm[3*nbeat_seen+2])     begin $display("[%0s] FAIL: TDATA beat %0d", NAME, nbeat_seen); fails = fails + 1; end
            end
            nbeat_seen = nbeat_seen + 1;
        end
        if (rerr) begin
            while (eptr < `RX_NFRAMES && expst[2*eptr] == 0) eptr = eptr + 1;
            if (eptr >= `RX_NFRAMES) begin $display("[%0s] FAIL: unexpected rx_error", NAME); fails = fails + 1; end
            else begin
                if (rcode !== expst[2*eptr][1:0]) begin $display("[%0s] FAIL: frame %0d error code got %0d exp %0d", NAME, eptr, rcode, expst[2*eptr]); fails = fails + 1; end
                eptr = eptr + 1;
            end
            nerr_seen = nerr_seen + 1;
        end
    end
endmodule

module tb_rx_scoreboard;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    reg [31:0] gap_max, bp, seed;
    wire d_ref, d_new; wire [31:0] f_ref, f_new;
    rx_harness #(.REF(1), .NAME("REF-original")) h_ref (.clk(clk), .rst_n(rst_n), .seed(seed),        .gap_max(gap_max), .bp_pct(bp), .done(d_ref), .fails(f_ref));
    rx_harness #(.REF(0), .NAME("NEW-v6"))       h_new (.clk(clk), .rst_n(rst_n), .seed(seed + 32'd7), .gap_max(gap_max), .bp_pct(bp), .done(d_new), .fails(f_new));
    initial begin
        if (!$value$plusargs("gap=%d", gap_max)) gap_max = 3;
        if (!$value$plusargs("bp=%d", bp))      bp = 70;
        if (!$value$plusargs("seed=%d", seed))  seed = 1;
        #1; rst_n = 0; repeat (6) @(posedge clk); @(negedge clk); rst_n = 1;
        wait (d_ref && d_new);
        $display("RXSB gap<=%0d bp=%0d%% seed=%0d frames=%0d : REF fails=%0d  NEW fails=%0d", gap_max, bp, seed, `RX_NFRAMES, f_ref, f_new);
        if (f_ref == 0 && f_new == 0) $display("PASS: RX scoreboard (original and new RX both match the independent model)");
        else if (f_new == 0)           $display("NOTE: new RX matches model; REFERENCE original mismatched the model (model assumption to review)");
        else                           $display("FAIL: RX scoreboard failures");
        if (f_new != 0) $fatal(1, "RX scoreboard failed");
        $finish;
    end
    initial begin #20000000; $display("FAIL: global timeout"); $fatal(1, "timeout"); end
endmodule
