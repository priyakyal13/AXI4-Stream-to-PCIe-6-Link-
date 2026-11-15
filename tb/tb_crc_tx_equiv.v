`timescale 1ns/1ps
// (1) crc32_meta_272 (new, flat XOR) vs original bit-serial module vs zlib-derived vectors.
// (2) layer4_flit_to_phy_lanes_framed (uses the new CRC) vs the ORIGINAL framed TX, cycle-exact,
//     random flit data / metadata / output-ready pattern.
module tb_crc_tx_equiv;
    reg [271:0] m; wire [31:0] c_new, c_ref;
    crc32_meta_272     u_new (.data(m), .crc(c_new));
    crc32_meta_272_ref u_ref (.data(m), .crc(c_ref));
    integer i, fails, nvec;
    reg clk = 0, rst_n = 0; always #5 clk = ~clk;
    // ---- TX pair
    reg [2047:0] fd; reg [31:0] fcrc; reg [255:0] fkeep; reg [3:0] flast, fbv; reg fvalid, lane_ready;
    wire rdy_n, rdy_r, lv_n, lv_r; wire [595:0] n0,n1,n2,n3,r0,r1,r2,r3;
    layer4_flit_to_phy_lanes_framed     tx_new (.clk(clk), .rst_n(rst_n), .s_flit_data(fd), .s_flit_crc(fcrc), .s_flit_tkeep(fkeep), .s_flit_tlasts(flast), .s_flit_beat_valid(fbv), .s_flit_valid(fvalid), .s_flit_ready(rdy_n), .m_lane0_data(n0), .m_lane1_data(n1), .m_lane2_data(n2), .m_lane3_data(n3), .m_lane_valid(lv_n), .m_lane_ready(lane_ready));
    layer4_flit_to_phy_lanes_framed_ref tx_ref (.clk(clk), .rst_n(rst_n), .s_flit_data(fd), .s_flit_crc(fcrc), .s_flit_tkeep(fkeep), .s_flit_tlasts(flast), .s_flit_beat_valid(fbv), .s_flit_valid(fvalid), .s_flit_ready(rdy_r), .m_lane0_data(r0), .m_lane1_data(r1), .m_lane2_data(r2), .m_lane3_data(r3), .m_lane_valid(lv_r), .m_lane_ready(lane_ready));
    reg [31:0] s; function [31:0] nx(input [31:0] x); reg [31:0] y; begin y = x ^ (x<<13); y = y ^ (y>>17); y = y ^ (y<<5); nx = y; end endfunction
    integer cyc, txf, accepted;
    // sim/meta_crc_vec.hex has two words per line: <272-bit data> <crc32>
    reg [271:0] vtmp [0:6547]; integer k;
    initial begin
        fails = 0; nvec = 0; accepted = 0;
        $readmemh("sim/meta_crc_vec.hex", vtmp);
        for (k = 0; k < 3274; k = k + 1) begin
            m = vtmp[2*k]; #1;
            if (c_new !== c_ref)       begin fails = fails + 1; $display("FAIL meta CRC new!=ref data=%h new=%h ref=%h", m, c_new, c_ref); end
            if (c_new !== vtmp[2*k+1][31:0]) begin fails = fails + 1; $display("FAIL meta CRC new!=zlib data=%h new=%h zlib=%h", m, c_new, vtmp[2*k+1][31:0]); end
            nvec = nvec + 1;
        end
        // 20000 extra random compares new vs original
        s = 32'h1234567;
        for (k = 0; k < 20000; k = k + 1) begin
            s = nx(s); m[31:0] = s; s = nx(s); m[63:32] = s; s = nx(s); m[95:64] = s; s = nx(s); m[127:96] = s;
            s = nx(s); m[159:128] = s; s = nx(s); m[191:160] = s; s = nx(s); m[223:192] = s; s = nx(s); m[255:224] = s; s = nx(s); m[271:256] = s[15:0];
            #1; if (c_new !== c_ref) begin fails = fails + 1; $display("FAIL meta CRC random mismatch"); end
            nvec = nvec + 1;
        end
        $display("meta-CRC: %0d vectors compared (new vs original vs zlib), fails=%0d", nvec, fails);
        // ---- TX equivalence
        fvalid = 0; lane_ready = 0; fd = 0; fcrc = 0; fkeep = 0; flast = 0; fbv = 0;
        repeat (4) @(posedge clk); @(negedge clk); rst_n = 1;
        for (cyc = 0; cyc < 4000; cyc = cyc + 1) begin
            @(negedge clk);
            s = nx(s); lane_ready = (s[3:0] < 4'd9);
            s = nx(s); fvalid = (s[2:0] != 3'd0);
            if (rdy_n === 1'b1) begin   // new data only when previous accepted (same for both: ready is identical)
                for (txf = 0; txf < 64; txf = txf + 1) begin s = nx(s); fd[txf*32 +: 32] = s; end
                for (txf = 0; txf < 8; txf = txf + 1)  begin s = nx(s); fkeep[txf*32 +: 32] = s; end
                s = nx(s); fcrc = s; s = nx(s); flast = s[3:0]; fbv = s[7:4];
            end
            #1;
            if (rdy_n !== rdy_r || lv_n !== lv_r) begin fails = fails + 1; $display("FAIL TX handshake mismatch @%0d", cyc); end
            if (lv_n && {n3,n2,n1,n0} !== {r3,r2,r1,r0}) begin fails = fails + 1; $display("FAIL TX lane data mismatch @%0d", cyc); end
            if (fvalid && rdy_n) accepted = accepted + 1;
        end
        $display("TX framed equivalence: 4000 cycles, %0d frames accepted, fails=%0d", accepted, fails);
        if (fails == 0) $display("PASS: CRC/TX equivalence"); else $display("FAIL: CRC/TX equivalence failures=%0d", fails);
        if (fails != 0) $fatal(1, "equiv failed");
        $finish;
    end
endmodule
