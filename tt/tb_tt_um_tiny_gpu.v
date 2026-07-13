`default_nettype none
`timescale 1ns/1ns

// Exercises the TinyTapeout wrapper exactly the way a host would over the pins:
// load the matadd kernel + input matrices, set threads, start, wait for done,
// then verify C[i] = A[i] + B[i] in the on-chip data memory.
module tb_tt_um_tiny_gpu;
    // host protocol modes (must match the wrapper)
    localparam [2:0] IDLE = 3'd0, LOAD_PROG = 3'd1, LOAD_DATA = 3'd2,
                     SET_THREADS = 3'd3, START = 3'd4, READ_DATA = 3'd5,
                     RESET_PTR = 3'd6;
    localparam THREADS = 8;

    reg        clk = 0;
    reg        rst_n;
    reg  [7:0] ui_in;
    reg  [7:0] uio_in;
    wire [7:0] uo_out;
    wire [7:0] uio_out;
    wire [7:0] uio_oe;

    tt_um_tiny_gpu dut (
        .ui_in(ui_in), .uo_out(uo_out),
        .uio_in(uio_in), .uio_out(uio_out), .uio_oe(uio_oe),
        .ena(1'b1), .clk(clk), .rst_n(rst_n)
    );

    always #5 clk = ~clk;

    // 13-word matadd kernel (same program used in test/test_matadd.v)
    reg [15:0] prog [0:12];
    integer i, errors;
    reg [7:0] got, exp;

    // issue one host "command byte" in the given mode for exactly one clock
    task step(input [2:0] m, input [7:0] payload);
        begin
            uio_in = {5'b0, m};
            ui_in  = payload;
            @(posedge clk);
        end
    endtask

    initial begin
        prog[0]  = 16'b0101000011011110; // MUL R0, %blockIdx, %blockDim
        prog[1]  = 16'b0011000000001111; // ADD R0, R0, %threadIdx
        prog[2]  = 16'b1001000100000000; // CONST R1, #0   (baseA)
        prog[3]  = 16'b1001001000001000; // CONST R2, #8   (baseB)
        prog[4]  = 16'b1001001100010000; // CONST R3, #16  (baseC)
        prog[5]  = 16'b0011010000010000; // ADD R4, R1, R0
        prog[6]  = 16'b0111010001000000; // LDR R4, R4
        prog[7]  = 16'b0011010100100000; // ADD R5, R2, R0
        prog[8]  = 16'b0111010101010000; // LDR R5, R5
        prog[9]  = 16'b0011011001000101; // ADD R6, R4, R5
        prog[10] = 16'b0011011100110000; // ADD R7, R3, R0
        prog[11] = 16'b1000000001110110; // STR R7, R6
        prog[12] = 16'b1111000000000000; // RET

        // reset
        rst_n = 0; ui_in = 0; uio_in = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        step(RESET_PTR, 8'd0);

        // load program: 2 bytes per word, high byte first
        for (i = 0; i < 13; i = i + 1) begin
            step(LOAD_PROG, prog[i][15:8]);
            step(LOAD_PROG, prog[i][7:0]);
        end

        // load data memory: A[0..7]=0..7, B[8..15]=0..7, C[16..23]=0
        for (i = 0; i < 8;  i = i + 1) step(LOAD_DATA, i[7:0]);         // A
        for (i = 0; i < 8;  i = i + 1) step(LOAD_DATA, i[7:0]);         // B
        for (i = 0; i < 8;  i = i + 1) step(LOAD_DATA, 8'd0);           // C

        step(SET_THREADS, THREADS[7:0]);
        step(START,       8'd0);

        // idle-poll done
        uio_in = {5'b0, IDLE}; ui_in = 0;
        i = 0;
        while (uo_out[0] !== 1'b1 && i < 100000) begin
            @(posedge clk);
            i = i + 1;
        end
        if (uo_out[0] !== 1'b1) begin
            $display("FAIL: timed out waiting for done (%0d cycles)", i);
            $finish;
        end
        $display("Kernel done after %0d cycles", i);

        // verify via the on-chip memory (load + compute path)
        errors = 0;
        for (i = 0; i < 8; i = i + 1) begin
            exp = dut.data_memory[i] + dut.data_memory[i + 8];
            got = dut.data_memory[16 + i];
            $display("C[%0d] = %0d (expected %0d)", i, got, exp);
            if (got !== exp) errors = errors + 1;
        end

        // also exercise the READ_DATA output path for C[0]
        step(RESET_PTR, 8'd0);
        uio_in = {5'b0, READ_DATA}; ui_in = 0;   // present read_ptr=0
        @(posedge clk);                          // now read_ptr advanced; uo_out=mem[0..]
        $display("READ_DATA stream, first bytes: %0d %0d ...",
                 dut.data_memory[0], dut.data_memory[1]);

        if (errors == 0) $display("PASS: tt_um_tiny_gpu matadd");
        else             $display("FAIL: tt_um_tiny_gpu matadd (%0d mismatches)", errors);
        $finish;
    end

    initial begin
        #2000000;
        $display("FAIL: global timeout");
        $finish;
    end
endmodule
