IVERILOG = iverilog
VVP      = vvp
GTKWAVE  = gtkwave

RTL_DIR  = rtl
TB_DIR   = tb
SIM_DIR  = sim
RES_DIR  = results

.PHONY: all layer1 layer2 layer3 layer4 top clean

# Full 4-layer split pipeline (recommended target for the report/demo)
all: layer1 layer2 layer3 layer4 top

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
	$(IVERILOG) -g2012 -o $(SIM_DIR)/layer3.out $(TB_DIR)/tb_layer3_flit_packetizer.v $(RTL_DIR)/layer3_flit_packetizer.v
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
		$(RTL_DIR)/layer3_flit_packetizer.v $(RTL_DIR)/layer4_flit_to_phy_lanes.v
	$(VVP) $(SIM_DIR)/top.out | tee $(RES_DIR)/integration_result.log

wave:
	$(GTKWAVE) $(SIM_DIR)/dump_top_4layer_true_split.vcd &

clean:
	rm -rf $(SIM_DIR) $(RES_DIR)/*.log
