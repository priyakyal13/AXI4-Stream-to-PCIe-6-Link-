# GTKWave screenshots (generated from the VCDs in `sim/`)
| File | Signals shown (module under test) |
|---|---|
| Fig1.png | clk, rst_n, s_tvalid/s_tready, s_tdata/tkeep/tlast — Layer 1 ingress slice |
| Fig2.png | s_axis1_*, m_axis_* — Layer 2 arbiter (packet-atomic grants) |
| Fig3.png | s_axis_tvalid/tready/tdata/tkeep/tlast — Layer 3 input beats |
| Fig4.png | s_flit_data, m_lane0..3_data, m_lane_valid/ready — Layer 4 FLIT → four lanes |
| Fig5.png | top-level bidir loopback: s0/s1 sources, tx_lane0..3, m_* output, rx_error, rx_good/bad_frames |
| Fig6.png | corrupt_enable, tx/rx lane valid/ready, rx_error, rx_error_code, good/bad frame counters |
| Fig7.png | m_valid/m_ready/m_data/m_keep/m_last, rx_lane_valid/ready, s0/s1_valid |
| Fig8.png | clk, rst_n, m_tready, m_tvalid |
Captions describe the signal lists visible in each screenshot. Raw waveforms: `sim/dump_layer1_axis_stream_ingress.vcd`, `dump_layer2_axis_arbiter.vcd`, `dump_layer3_flit_packetizer.vcd`, `dump_layer4_flit_to_phy_lanes.vcd`, `dump_top_4layer_bidir.vcd`, `dump_top_4layer_true_split.vcd`.
