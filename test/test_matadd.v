`default_nettype none
`timescale 1ns/1ns

// MATRIX ADDITION TESTBENCH
// > Models external program & data memory, loads the matadd kernel,
//   writes the thread count to the device control register, and starts the GPU
// > Runs until `done` and checks C[i] = A[i] + B[i] in data memory
// > Multi-channel memory buses are flattened: channel i occupies bits [WIDTH*i +: WIDTH]
module test_matadd;
    localparam PROGRAM_MEM_ADDR_BITS = 8;
    localparam PROGRAM_MEM_DATA_BITS = 16;
    localparam PROGRAM_MEM_NUM_CHANNELS = 1;
    localparam DATA_MEM_ADDR_BITS = 8;
    localparam DATA_MEM_DATA_BITS = 8;
    localparam DATA_MEM_NUM_CHANNELS = 4;
    localparam THREADS = 8;
    localparam MAX_CYCLES = 50000;

    reg clk = 0;
    reg reset;
    reg start;
    wire done;

    reg device_control_write_enable;
    reg [7:0] device_control_data;

    // Program Memory
    wire [PROGRAM_MEM_NUM_CHANNELS-1:0] program_mem_read_valid;
    wire [PROGRAM_MEM_NUM_CHANNELS*PROGRAM_MEM_ADDR_BITS-1:0] program_mem_read_address;
    reg [PROGRAM_MEM_NUM_CHANNELS-1:0] program_mem_read_ready;
    reg [PROGRAM_MEM_NUM_CHANNELS*PROGRAM_MEM_DATA_BITS-1:0] program_mem_read_data;

    // Data Memory
    wire [DATA_MEM_NUM_CHANNELS-1:0] data_mem_read_valid;
    wire [DATA_MEM_NUM_CHANNELS*DATA_MEM_ADDR_BITS-1:0] data_mem_read_address;
    reg [DATA_MEM_NUM_CHANNELS-1:0] data_mem_read_ready;
    reg [DATA_MEM_NUM_CHANNELS*DATA_MEM_DATA_BITS-1:0] data_mem_read_data;
    wire [DATA_MEM_NUM_CHANNELS-1:0] data_mem_write_valid;
    wire [DATA_MEM_NUM_CHANNELS*DATA_MEM_ADDR_BITS-1:0] data_mem_write_address;
    wire [DATA_MEM_NUM_CHANNELS*DATA_MEM_DATA_BITS-1:0] data_mem_write_data;
    reg [DATA_MEM_NUM_CHANNELS-1:0] data_mem_write_ready;

    gpu dut (
        .clk(clk),
        .reset(reset),
        .start(start),
        .done(done),

        .device_control_write_enable(device_control_write_enable),
        .device_control_data(device_control_data),

        .program_mem_read_valid(program_mem_read_valid),
        .program_mem_read_address(program_mem_read_address),
        .program_mem_read_ready(program_mem_read_ready),
        .program_mem_read_data(program_mem_read_data),

        .data_mem_read_valid(data_mem_read_valid),
        .data_mem_read_address(data_mem_read_address),
        .data_mem_read_ready(data_mem_read_ready),
        .data_mem_read_data(data_mem_read_data),
        .data_mem_write_valid(data_mem_write_valid),
        .data_mem_write_address(data_mem_write_address),
        .data_mem_write_data(data_mem_write_data),
        .data_mem_write_ready(data_mem_write_ready)
    );

    // Back-annotate gate delays onto the synthesized netlist for gate-level
    // simulation (path is relative to simulation/work/, where sim-nc runs).
    // Enable with +define+SDF (sim-nc -sdf); leave off for RTL simulation.
`ifdef SDF
    initial begin
        $sdf_annotate("../../src/gpu_syn.sdf",
                      test_matadd.dut);
    end
`endif

    // External memory (behavioral)
    reg [PROGRAM_MEM_DATA_BITS-1:0] program_memory [0:(2**PROGRAM_MEM_ADDR_BITS)-1];
    reg [DATA_MEM_DATA_BITS-1:0] data_memory [0:(2**DATA_MEM_ADDR_BITS)-1];


    always #5 clk = ~clk;

    // Respond to memory requests once per cycle, mid-cycle, so the GPU's
    // memory controllers sample the response on the following rising edge
    integer c;
    always @(negedge clk) begin
        for (c = 0; c < PROGRAM_MEM_NUM_CHANNELS; c = c + 1) begin
            if (program_mem_read_valid[c]) begin
                program_mem_read_data[PROGRAM_MEM_DATA_BITS*c +: PROGRAM_MEM_DATA_BITS] <=
                    program_memory[program_mem_read_address[PROGRAM_MEM_ADDR_BITS*c +: PROGRAM_MEM_ADDR_BITS]];
                program_mem_read_ready[c] <= 1;
            end else begin
                program_mem_read_ready[c] <= 0;
            end
        end

        for (c = 0; c < DATA_MEM_NUM_CHANNELS; c = c + 1) begin
            if (data_mem_read_valid[c]) begin
                data_mem_read_data[DATA_MEM_DATA_BITS*c +: DATA_MEM_DATA_BITS] <=
                    data_memory[data_mem_read_address[DATA_MEM_ADDR_BITS*c +: DATA_MEM_ADDR_BITS]];
                data_mem_read_ready[c] <= 1;
            end else begin
                data_mem_read_ready[c] <= 0;
            end

            if (data_mem_write_valid[c]) begin
                data_memory[data_mem_write_address[DATA_MEM_ADDR_BITS*c +: DATA_MEM_ADDR_BITS]] <=
                    data_mem_write_data[DATA_MEM_DATA_BITS*c +: DATA_MEM_DATA_BITS];
                data_mem_write_ready[c] <= 1;
            end else begin
                data_mem_write_ready[c] <= 0;
            end
        end
    end

    task display_data_memory;
        input integer rows;
        integer r;
        begin
            $display("");
            $display("DATA MEMORY");
            $display("+-----------------+");
            $display("| Addr | Data     |");
            $display("+-----------------+");
            for (r = 0; r < rows; r = r + 1)
                $display("| %-4d | %-8d |", r, data_memory[r]);
            $display("+-----------------+");
        end
    endtask

    integer i;
    integer cycles;
    integer errors;
    reg [DATA_MEM_DATA_BITS-1:0] expected;

    initial begin
        // Program Memory
        for (i = 0; i < 2**PROGRAM_MEM_ADDR_BITS; i = i + 1)
            program_memory[i] = 0;
        program_memory[0]  = 16'b0101000011011110; // MUL R0, %blockIdx, %blockDim
        program_memory[1]  = 16'b0011000000001111; // ADD R0, R0, %threadIdx         ; i = blockIdx * blockDim + threadIdx
        program_memory[2]  = 16'b1001000100000000; // CONST R1, #0                   ; baseA (matrix A base address)
        program_memory[3]  = 16'b1001001000001000; // CONST R2, #8                   ; baseB (matrix B base address)
        program_memory[4]  = 16'b1001001100010000; // CONST R3, #16                  ; baseC (matrix C base address)
        program_memory[5]  = 16'b0011010000010000; // ADD R4, R1, R0                 ; addr(A[i]) = baseA + i
        program_memory[6]  = 16'b0111010001000000; // LDR R4, R4                     ; load A[i] from global memory
        program_memory[7]  = 16'b0011010100100000; // ADD R5, R2, R0                 ; addr(B[i]) = baseB + i
        program_memory[8]  = 16'b0111010101010000; // LDR R5, R5                     ; load B[i] from global memory
        program_memory[9]  = 16'b0011011001000101; // ADD R6, R4, R5                 ; C[i] = A[i] + B[i]
        program_memory[10] = 16'b0011011100110000; // ADD R7, R3, R0                 ; addr(C[i]) = baseC + i
        program_memory[11] = 16'b1000000001110110; // STR R7, R6                     ; store C[i] in global memory
        program_memory[12] = 16'b1111000000000000; // RET                            ; end of kernel

        // Data Memory: Matrix A (1 x 8) at 0, Matrix B (1 x 8) at 8
        for (i = 0; i < 2**DATA_MEM_ADDR_BITS; i = i + 1)
            data_memory[i] = 0;
        for (i = 0; i < 8; i = i + 1) begin
            data_memory[i] = i;
            data_memory[i + 8] = i;
        end

        program_mem_read_ready = 0;
        program_mem_read_data = 0;
        data_mem_read_ready = 0;
        data_mem_read_data = 0;
        data_mem_write_ready = 0;

        // Reset (drive stimulus with non-blocking assignments so the DUT
        // samples the old value at the clock edge)
        reset = 1;
        start = 0;
        device_control_write_enable = 0;
        device_control_data = 0;
        @(posedge clk);
        reset <= 0;

        // Device Control Register
        device_control_write_enable <= 1;
        device_control_data <= THREADS;
        @(posedge clk);
        device_control_write_enable <= 0;

        // Start
        start <= 1;

        display_data_memory(24);

        cycles = 0;
        while (done !== 1'b1 && cycles < MAX_CYCLES) begin
            @(posedge clk);
            cycles = cycles + 1;
        end

        if (done !== 1'b1) begin
            $display("FAIL: timed out after %0d cycles", cycles);
            $finish;
        end

        $display("Completed in %0d cycles", cycles);
        display_data_memory(24);

        errors = 0;
        for (i = 0; i < 8; i = i + 1) begin
            expected = data_memory[i] + data_memory[i + 8];
            if (data_memory[16 + i] !== expected) begin
                $display("FAIL: result mismatch at index %0d: expected %0d, got %0d",
                    i, expected, data_memory[16 + i]);
                errors = errors + 1;
            end
        end

        if (errors == 0)
            $display("PASS: test_matadd");
        else
            $display("FAIL: test_matadd (%0d mismatches)", errors);
        $finish;
    end
endmodule
