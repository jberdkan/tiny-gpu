`default_nettype none
`timescale 1ns/1ns

// MATRIX MULTIPLICATION TESTBENCH
// > Models external program & data memory, loads the matmul kernel,
//   writes the thread count to the device control register, and starts the GPU
// > Runs until `done` and checks C = A * B (2x2 matrices) in data memory
// > Multi-channel memory buses are flattened: channel i occupies bits [WIDTH*i +: WIDTH]
module test_matmul;
    localparam PROGRAM_MEM_ADDR_BITS = 8;
    localparam PROGRAM_MEM_DATA_BITS = 16;
    localparam PROGRAM_MEM_NUM_CHANNELS = 1;
    localparam DATA_MEM_ADDR_BITS = 8;
    localparam DATA_MEM_DATA_BITS = 8;
    localparam DATA_MEM_NUM_CHANNELS = 4;
    localparam THREADS = 4;
    localparam N = 2; // matrix inner dimension
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
                      test_matmul.dut);
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

    integer i, row, col, k;
    integer cycles;
    integer errors;
    reg [DATA_MEM_DATA_BITS-1:0] expected_results [0:(N*N)-1];

    initial begin
        // Program Memory
        for (i = 0; i < 2**PROGRAM_MEM_ADDR_BITS; i = i + 1)
            program_memory[i] = 0;
        program_memory[0]  = 16'b0101000011011110; // MUL R0, %blockIdx, %blockDim
        program_memory[1]  = 16'b0011000000001111; // ADD R0, R0, %threadIdx         ; i = blockIdx * blockDim + threadIdx
        program_memory[2]  = 16'b1001000100000001; // CONST R1, #1                   ; increment
        program_memory[3]  = 16'b1001001000000010; // CONST R2, #2                   ; N (matrix inner dimension)
        program_memory[4]  = 16'b1001001100000000; // CONST R3, #0                   ; baseA (matrix A base address)
        program_memory[5]  = 16'b1001010000000100; // CONST R4, #4                   ; baseB (matrix B base address)
        program_memory[6]  = 16'b1001010100001000; // CONST R5, #8                   ; baseC (matrix C base address)
        program_memory[7]  = 16'b0110011000000010; // DIV R6, R0, R2                 ; row = i // N
        program_memory[8]  = 16'b0101011101100010; // MUL R7, R6, R2
        program_memory[9]  = 16'b0100011100000111; // SUB R7, R0, R7                 ; col = i % N
        program_memory[10] = 16'b1001100000000000; // CONST R8, #0                   ; acc = 0
        program_memory[11] = 16'b1001100100000000; // CONST R9, #0                   ; k = 0
                                                   // LOOP:
        program_memory[12] = 16'b0101101001100010; //   MUL R10, R6, R2
        program_memory[13] = 16'b0011101010101001; //   ADD R10, R10, R9
        program_memory[14] = 16'b0011101010100011; //   ADD R10, R10, R3             ; addr(A[i]) = row * N + k + baseA
        program_memory[15] = 16'b0111101010100000; //   LDR R10, R10                 ; load A[i] from global memory
        program_memory[16] = 16'b0101101110010010; //   MUL R11, R9, R2
        program_memory[17] = 16'b0011101110110111; //   ADD R11, R11, R7
        program_memory[18] = 16'b0011101110110100; //   ADD R11, R11, R4             ; addr(B[i]) = k * N + col + baseB
        program_memory[19] = 16'b0111101110110000; //   LDR R11, R11                 ; load B[i] from global memory
        program_memory[20] = 16'b0101110010101011; //   MUL R12, R10, R11
        program_memory[21] = 16'b0011100010001100; //   ADD R8, R8, R12              ; acc = acc + A[i] * B[i]
        program_memory[22] = 16'b0011100110010001; //   ADD R9, R9, R1               ; increment k
        program_memory[23] = 16'b0010000010010010; //   CMP R9, R2
        program_memory[24] = 16'b0001100000001100; //   BRn LOOP                     ; loop while k < N
        program_memory[25] = 16'b0011100101010000; // ADD R9, R5, R0                 ; addr(C[i]) = baseC + i
        program_memory[26] = 16'b1000000010011000; // STR R9, R8                     ; store C[i] in global memory
        program_memory[27] = 16'b1111000000000000; // RET                            ; end of kernel

        // Data Memory: Matrix A (2 x 2) at 0, Matrix B (2 x 2) at 4
        for (i = 0; i < 2**DATA_MEM_ADDR_BITS; i = i + 1)
            data_memory[i] = 0;
        data_memory[0] = 1; data_memory[1] = 2; data_memory[2] = 3; data_memory[3] = 4; // A
        data_memory[4] = 1; data_memory[5] = 2; data_memory[6] = 3; data_memory[7] = 4; // B

        // Expected: C[row][col] = sum_k A[row][k] * B[k][col], stored at baseC = 8
        for (row = 0; row < N; row = row + 1)
            for (col = 0; col < N; col = col + 1) begin
                expected_results[row * N + col] = 0;
                for (k = 0; k < N; k = k + 1)
                    expected_results[row * N + col] = expected_results[row * N + col]
                        + data_memory[row * N + k] * data_memory[4 + k * N + col];
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

        display_data_memory(12);

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
        display_data_memory(12);

        errors = 0;
        for (i = 0; i < N * N; i = i + 1) begin
            if (data_memory[8 + i] !== expected_results[i]) begin
                $display("FAIL: result mismatch at index %0d: expected %0d, got %0d",
                    i, expected_results[i], data_memory[8 + i]);
                errors = errors + 1;
            end
        end

        if (errors == 0)
            $display("PASS: test_matmul");
        else
            $display("FAIL: test_matmul (%0d mismatches)", errors);
        $finish;
    end
endmodule
