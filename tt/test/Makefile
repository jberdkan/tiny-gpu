# cocotb test for tt_um_tiny_gpu (TinyTapeout style).
#
#   Local RTL run:   pip install cocotb ; make
#   Gate-level:      make GATES=yes   (needs the sky130 cell models; TT CI does this)
#
# TinyTapeout's CI runs this automatically on every push.

SIM ?= icarus
TOPLEVEL_LANG ?= verilog

# Repo layout: the wrapper lives in tt/, the gpu RTL in src/. In the official
# TinyTapeout template all sources sit in src/ -- adjust these two dirs if you
# copy this test into a TT template fork.
WRAPPER_DIR = $(PWD)/..
RTL_DIR     = $(PWD)/../../src

ifneq ($(GATES),yes)

# ---- RTL simulation ----
VERILOG_SOURCES += $(WRAPPER_DIR)/tt_um_tiny_gpu.v
VERILOG_SOURCES += \
	$(RTL_DIR)/alu.v $(RTL_DIR)/dcr.v $(RTL_DIR)/decoder.v $(RTL_DIR)/fetcher.v \
	$(RTL_DIR)/lsu.v $(RTL_DIR)/pc.v $(RTL_DIR)/registers.v $(RTL_DIR)/scheduler.v \
	$(RTL_DIR)/controller.v $(RTL_DIR)/dispatch.v $(RTL_DIR)/core.v $(RTL_DIR)/gpu.v
# match the hardening build: drop the ALU divider
COMPILE_ARGS += -DNO_DIV=1

else

# ---- gate-level simulation (needs sky130 std-cell models from the PDK) ----
VERILOG_SOURCES += $(WRAPPER_DIR)/tapeout/tt_um_tiny_gpu.nl.v
COMPILE_ARGS += -DGL_TEST -DFUNCTIONAL -DUSE_POWER_PINS -DUNIT_DELAY=\#1

endif

VERILOG_SOURCES += $(PWD)/tb.v
TOPLEVEL = tb
MODULE   = test

include $(shell cocotb-config --makefiles)/Makefile.sim
