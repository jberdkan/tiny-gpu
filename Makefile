.PHONY: test

# RTL only — exclude synthesis/scan outputs (gpu_syn.v, gpu_scan.v) that DC writes into src/
RTL_SRCS = $(filter-out $(wildcard src/*_syn.v) $(wildcard src/*_scan.v), $(wildcard src/*.v))

test: test_matadd test_matmul

test_%: test/test_%.v $(RTL_SRCS)
	mkdir -p build
	iverilog -g2005 -o build/test_$*.vvp -s test_$* $(RTL_SRCS) test/test_$*.v
	vvp build/test_$*.vvp

show_%: %.vcd %.gtkw
	gtkwave $^
