# Requires Icarus Verilog (iverilog + vvp) and, optionally, GTKWave.
#   Ubuntu/Debian: sudo apt install iverilog gtkwave

SIM_DIR = sim

.PHONY: all sim wave clean

all: sim

sim: $(SIM_DIR)
	iverilog -g2012 -o $(SIM_DIR)/fifo_tb.vvp sync_fifo.sv tb_sync_fifo.sv
	vvp $(SIM_DIR)/fifo_tb.vvp

wave: sim
	gtkwave $(SIM_DIR)/fifo_wave.vcd &

$(SIM_DIR):
	mkdir -p $(SIM_DIR)

clean:
	rm -rf $(SIM_DIR)/*.vvp $(SIM_DIR)/*.vcd
