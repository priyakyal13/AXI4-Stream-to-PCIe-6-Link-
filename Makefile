IVERILOG = iverilog
VVP      = vvp
GTKWAVE  = gtkwave

RTL_DIR  = rtl
TB_DIR   = tb
SIM_DIR  = sim
RES_DIR  = results

.PHONY: all layer1 layer2 layer3 layer4 top bidir protocol-check random regression clean

# Full 4-layer split pipeline (recommended target for the report/demo)
all: layer1 layer2 layer3 layer4 top bidir protocol-check

layer1:
	mkdir -p $(SIM_DIR) $(RES_DIR)
	$(IVERILOG) -g2012 -o $(SIM_DIR)/layer1.out $(TB_DIR)/tb_layer1_axis_stream_ingress.v $(RTL_DIR)/layer1_axis_stream_ingress.v
	$(VVP) $(SIM_DIR)/layer1.out | tee $(RES_DIR)/layer1_result.log

layer2:
	mkdir -p $(SIM_DIR) $(RES_DIR)
	$(IVERILOG) -g2012 -o $(SIM_DIR)/layer2.out $(TB_DIR)/tb_layer2_axis_arbiter.v $(RTL_DIR)/layer2_axis_arbiter.v
	$(VVP) $(SIM_DIR)/layer2.out | tee $(RES_DIR)/layer2_result.log

layer3:
	mkdir -p $(SIM_DIR) $(RES_DIR)
	$(IVERILOG) -g2012 -o $(SIM_DIR)/layer3.out $(TB_DIR)/tb_layer3_flit_packetizer.v $(RTL_DIR)/layer3_flit_packetizer.v $(RTL_DIR)/crc32_d512.v
	$(VVP) $(SIM_DIR)/layer3.out | tee $(RES_DIR)/layer3_result.log

layer4:
	mkdir -p $(SIM_DIR) $(RES_DIR)
	$(IVERILOG) -g2012 -o $(SIM_DIR)/layer4.out $(TB_DIR)/tb_layer4_flit_to_phy_lanes.v $(RTL_DIR)/layer4_flit_to_phy_lanes.v
	$(VVP) $(SIM_DIR)/layer4.out | tee $(RES_DIR)/layer4_result.log

# Full integration: 2 AXI4-Stream masters -> arbiter -> ingress ->
# packetizer+CRC -> lane-striped symbols (incl. backpressure test)
top:
	mkdir -p $(SIM_DIR) $(RES_DIR)
	$(IVERILOG) -g2012 -o $(SIM_DIR)/top.out $(TB_DIR)/tb_top_4layer_true_split.v $(RTL_DIR)/top_4layer_true_split.v \
		$(RTL_DIR)/layer1_axis_stream_ingress.v $(RTL_DIR)/layer2_axis_arbiter.v \
		$(RTL_DIR)/layer3_flit_packetizer.v $(RTL_DIR)/crc32_d512.v $(RTL_DIR)/layer4_flit_to_phy_lanes.v
	$(VVP) $(SIM_DIR)/top.out | tee $(RES_DIR)/integration_result.log


# New end-to-end bidirectional digital-link regression. This top adds RX,
# framing metadata (TKEEP/TLAST/valid-beat mask), metadata CRC, and data CRC
# checking. The testbench loops TX lane bundles into RX and injects one bad frame.
bidir:
	mkdir -p $(SIM_DIR) $(RES_DIR)
	$(IVERILOG) -g2012 -o $(SIM_DIR)/bidir.out $(TB_DIR)/tb_top_4layer_bidir.v \
		$(RTL_DIR)/top_4layer_bidir.v $(RTL_DIR)/layer1_axis_stream_ingress.v \
		$(RTL_DIR)/layer2_axis_arbiter.v $(RTL_DIR)/layer3_flit_packetizer.v \
		$(RTL_DIR)/crc32_d512.v $(RTL_DIR)/crc32_meta_272.v \
		$(RTL_DIR)/layer4_flit_to_phy_lanes_framed.v $(RTL_DIR)/layer4_phy_lanes_to_axis.v
	$(VVP) $(SIM_DIR)/bidir.out | tee $(RES_DIR)/bidir_result.log

# Pure-Python protocol cross-check (does not replace HDL simulation).
protocol-check:
	python3 scripts/check_bidir_protocol.py

# Run the directed/integrated suites plus representative Layer 3 workloads.
# Longer than `make all`; logs are kept under results/.
regression: all
	$(MAKE) random PROFILE=random N=500 SEED=1 STALL=40 GAP=3
	$(MAKE) random PROFILE=network N=300 STALL=0 GAP=0 SEED=11
	$(MAKE) random PROFILE=jumbo N=100 STALL=20 GAP=2 SEED=17
	$(MAKE) random PROFILE=ml N=100 STALL=0 GAP=0 SEED=23

# Randomised Layer 3 regression vs Python/zlib golden model.
#   make random                 (SEED=1, N=500 packets)
#   make random SEED=7 N=2000
#   make random PROFILE=network N=3000 STALL=0 GAP=0   (throughput, ideal ends)
#   profiles: random | network | jumbo | ml
SEED    ?= 1
N       ?= 500
PROFILE ?= random
STALL   ?= 40
GAP     ?= 3
random:
	mkdir -p $(SIM_DIR) $(RES_DIR)
	python3 scripts/gen_rand_l3.py $(SEED) $(N) $(PROFILE)
	$(IVERILOG) -g2012 -I$(SIM_DIR) -o $(SIM_DIR)/rand_l3.out $(TB_DIR)/tb_rand_layer3.v $(RTL_DIR)/layer3_flit_packetizer.v $(RTL_DIR)/crc32_d512.v
	$(VVP) $(SIM_DIR)/rand_l3.out +seed=$(SEED) +stall=$(STALL) +gap=$(GAP) | tee $(RES_DIR)/random_l3_result.log

wave:
	$(GTKWAVE) $(SIM_DIR)/dump_top_4layer_true_split.vcd &

clean:
	rm -rf $(SIM_DIR) $(RES_DIR)/*.log

# ---- v6 verification additions
rxsb:
	python3 scripts/gen_rx_vectors.py 1 600
	$(IVERILOG) -g2012 -I$(SIM_DIR) -o $(SIM_DIR)/rxsb.out tb/tb_rx_scoreboard.v $(RTL_DIR)/layer4_phy_lanes_to_axis.v $(RTL_DIR)/crc32_meta_272.v $(RTL_DIR)/crc32_d512.v tb/ref/ref_layer4_phy_lanes_to_axis.v tb/ref/ref_crc32_meta_272.v
	$(VVP) $(SIM_DIR)/rxsb.out +gap=3 +bp=70 +seed=1 | tee $(RES_DIR)/rx_scoreboard_result.log
crceq:
	python3 scripts/gen_meta_crc_vectors.py
	$(IVERILOG) -g2012 -o $(SIM_DIR)/crceq.out tb/tb_crc_tx_equiv.v $(RTL_DIR)/crc32_meta_272.v $(RTL_DIR)/layer4_flit_to_phy_lanes_framed.v tb/ref/ref_crc32_meta_272.v tb/ref/ref_layer4_flit_to_phy_lanes_framed.v
	$(VVP) $(SIM_DIR)/crceq.out | tee $(RES_DIR)/crc_tx_equiv_result.log
NPK ?= 40
TGAP ?= 2
TBP ?= 70
toprand:
	mkdir -p $(SIM_DIR) $(RES_DIR)
	$(IVERILOG) -g2012 -o $(SIM_DIR)/toprand.out tb/tb_top_bidir_random.v $(RTL_DIR)/top_4layer_bidir.v $(RTL_DIR)/layer1_axis_stream_ingress.v $(RTL_DIR)/layer2_axis_arbiter.v $(RTL_DIR)/layer3_flit_packetizer.v $(RTL_DIR)/crc32_d512.v $(RTL_DIR)/crc32_meta_272.v $(RTL_DIR)/layer4_flit_to_phy_lanes_framed.v $(RTL_DIR)/layer4_phy_lanes_to_axis.v
	$(VVP) $(SIM_DIR)/toprand.out +seed=$(SEED) +npk=$(NPK) +gap=$(TGAP) +bp=$(TBP) | tee $(RES_DIR)/top_random_result.log
