CC ?= clang
CFLAGS ?= -std=c11 -O2 -Wall -Wextra -pedantic

BUILD_DIR := build
SIM := $(BUILD_DIR)/simv
SIM_VGA := $(BUILD_DIR)/simv_vga

GEN := $(BUILD_DIR)/gen_tests
CHECK := $(BUILD_DIR)/check_output
FB2PPM := $(BUILD_DIR)/fb_to_ppm
HEX2W := $(BUILD_DIR)/logisim_hex_to_words

RTL := rtl/minirv.v
TB := tb/minirv_tb.v

OFF_DIR := tests/logisim-bin
OFF_MEM_SRC := $(OFF_DIR)/mem.hex
OFF_SUM_SRC := $(OFF_DIR)/sum.hex
OFF_VGA_SRC := $(OFF_DIR)/vga.hex
OFF_MEM_HEX := $(BUILD_DIR)/official_mem.hex
OFF_SUM_HEX := $(BUILD_DIR)/official_sum.hex
OFF_VGA_HEX := $(BUILD_DIR)/official_vga.hex

.PHONY: \
	all tools gen-tests sim \
	run-basic-mem run-basic-sum test-basic \
	prepare-official \
	run-official-mem run-official-sum run-official-vga test-official \
	clean

all: test-official

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(GEN): tools/gen_tests.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) $< -o $@

$(CHECK): tools/check_output.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) $< -o $@

$(FB2PPM): tools/fb_to_ppm.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) $< -o $@

$(HEX2W): tools/logisim_hex_to_words.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) $< -o $@

tools: $(GEN) $(CHECK) $(FB2PPM) $(HEX2W)

gen-tests: $(GEN)
	./$(GEN)

sim: $(RTL) $(TB) | $(BUILD_DIR)
	@if ! command -v iverilog >/dev/null 2>&1; then \
		echo "ERROR: iverilog not found. Install with: brew install icarus-verilog"; \
		exit 1; \
	fi
	iverilog -g2012 -o $(SIM) $(TB) $(RTL)

sim-vga: $(RTL) $(TB) | $(BUILD_DIR)
	@if ! command -v iverilog >/dev/null 2>&1; then \
		echo "ERROR: iverilog not found. Install with: brew install icarus-verilog"; \
		exit 1; \
	fi
	iverilog -g2012 -P minirv_tb.MEM_WORDS=163840 -o $(SIM_VGA) $(TB) $(RTL)

run-basic-mem: gen-tests sim $(CHECK)
	vvp $(SIM) +HEX=tests/mem.hex +MAX_CYCLES=120 > $(BUILD_DIR)/mem.log
	$(CHECK) --log $(BUILD_DIR)/mem.log --a0 0x00000012 --pc 0x00000020

run-basic-sum: gen-tests sim $(CHECK)
	vvp $(SIM) +HEX=tests/sum.hex +MAX_CYCLES=120 > $(BUILD_DIR)/sum.log
	$(CHECK) --log $(BUILD_DIR)/sum.log --a0 0x0007a314 --pc 0x00000044

test-basic: run-basic-mem run-basic-sum

$(OFF_MEM_HEX): $(OFF_MEM_SRC) $(HEX2W)
	$(HEX2W) $(OFF_MEM_SRC) $(OFF_MEM_HEX)

$(OFF_SUM_HEX): $(OFF_SUM_SRC) $(HEX2W)
	$(HEX2W) $(OFF_SUM_SRC) $(OFF_SUM_HEX)

$(OFF_VGA_HEX): $(OFF_VGA_SRC) $(HEX2W)
	$(HEX2W) $(OFF_VGA_SRC) $(OFF_VGA_HEX)

prepare-official: $(OFF_MEM_HEX) $(OFF_SUM_HEX) $(OFF_VGA_HEX)

run-official-mem: prepare-official sim $(CHECK)
	@if [ ! -f "$(OFF_MEM_SRC)" ]; then echo "Missing $(OFF_MEM_SRC)"; exit 1; fi
	vvp $(SIM) +HEX=$(OFF_MEM_HEX) +MAX_CYCLES=10000 > $(BUILD_DIR)/official_mem.log
	$(CHECK) --log $(BUILD_DIR)/official_mem.log --a0 0x0 --pc-range 0x00001218 0x00001220

run-official-sum: prepare-official sim $(CHECK)
	@if [ ! -f "$(OFF_SUM_SRC)" ]; then echo "Missing $(OFF_SUM_SRC)"; exit 1; fi
	vvp $(SIM) +HEX=$(OFF_SUM_HEX) +MAX_CYCLES=10000 > $(BUILD_DIR)/official_sum.log
	$(CHECK) --log $(BUILD_DIR)/official_sum.log --a0 0x0 --pc-range 0x00000224 0x0000022c

run-official-vga: prepare-official sim-vga $(CHECK) $(FB2PPM)
	@if [ ! -f "$(OFF_VGA_SRC)" ]; then echo "Missing $(OFF_VGA_SRC)"; exit 1; fi
	vvp $(SIM_VGA) +HEX=$(OFF_VGA_HEX) +MAX_CYCLES=650000 +FBDUMP=$(BUILD_DIR)/vga_fb.hex > $(BUILD_DIR)/official_vga.log
	$(CHECK) --log $(BUILD_DIR)/official_vga.log --a0 0x0 --fb-dump $(BUILD_DIR)/vga_fb.hex --min-nonzero-pixels 1000
	$(FB2PPM) $(BUILD_DIR)/vga_fb.hex $(BUILD_DIR)/vga.ppm
	@echo "Generated image: $(BUILD_DIR)/vga.ppm"

test-official: run-official-mem run-official-sum run-official-vga

clean:
	rm -rf $(BUILD_DIR) tests/mem.hex tests/sum.hex
