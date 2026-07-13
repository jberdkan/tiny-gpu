`default_nettype none
`timescale 1ns / 1ps

// Testbench harness for cocotb (TinyTapeout style). cocotb drives the ports
// from Python (see test.py); this file just wires up tt_um_tiny_gpu and dumps
// a VCD. `GL_TEST` selects the gate-level netlist power pins in CI.
module tb ();
    initial begin
        $dumpfile("tb.vcd");
        $dumpvars(0, tb);
    end

    reg        clk;
    reg        rst_n;
    reg        ena;
    reg  [7:0] ui_in;
    reg  [7:0] uio_in;
    wire [7:0] uo_out;
    wire [7:0] uio_out;
    wire [7:0] uio_oe;

`ifdef GL_TEST
    wire VPWR = 1'b1;
    wire VGND = 1'b0;
`endif

    tt_um_tiny_gpu user_project (
`ifdef GL_TEST
        .VPWR   (VPWR),
        .VGND   (VGND),
`endif
        .ui_in  (ui_in),
        .uo_out (uo_out),
        .uio_in (uio_in),
        .uio_out(uio_out),
        .uio_oe (uio_oe),
        .ena    (ena),
        .clk    (clk),
        .rst_n  (rst_n)
    );
endmodule
