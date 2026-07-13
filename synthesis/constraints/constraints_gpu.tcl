##################################################################
#### Timing constraints for tiny-gpu (top module: gpu)
#### ECE 6214 course-style constraints, equivalent to the supplied
#### program_counter constraints but written with port collections
#### because gpu has ~183 ports
#### Sourced by synthesis_gpu.tcl before compile; write_sdc exports
#### the expanded per-port version for Innovus afterwards
##################################################################

set_max_capacitance 0.5 [current_design]
set_max_transition 1.5 [current_design]

# 0.2 pF pin load on every output
set_load -pin_load 0.2 [all_outputs]

# max fanout of 1 on every input
set_max_fanout 1 [all_inputs]

# main clock: 10 ns period (100 MHz)
# NOTE: the single-cycle 8-bit divider in the ALU is the critical path.
# If report_timing shows negative slack at ss_125, raise the period here
# AND in synthesis/netlists/gpu_postcts.sdc (e.g. to 20) and re-run.
create_clock [get_ports clk]  -period 10  -waveform {0 5}
set_clock_latency 0  [get_clocks clk]
set_clock_uncertainty -setup 0.2  [get_clocks clk]
set_clock_uncertainty -hold 0  [get_clocks clk]
set_clock_transition -max -rise 0.1 [get_clocks clk]
set_clock_transition -min -rise 0.1 [get_clocks clk]
set_clock_transition -max -fall 0.12 [get_clocks clk]
set_clock_transition -min -fall 0.12 [get_clocks clk]

# virtual clock for I/O timing
create_clock -name v_clk  -period 10  -waveform {0 5}

# 1 ns input delay on every input except the clock, relative to v_clk
set_input_delay -clock v_clk 1 [remove_from_collection [all_inputs] [get_ports clk]]

# 1 ns output delay on every output, relative to v_clk
set_output_delay -clock v_clk 1 [all_outputs]

# input transition times on every input
set_input_transition -max -rise 0.1  [all_inputs]
set_input_transition -max -fall 0.12 [all_inputs]
set_input_transition -min -rise 0.1  [all_inputs]
set_input_transition -min -fall 0.12 [all_inputs]
