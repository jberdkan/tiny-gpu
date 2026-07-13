`default_nettype none
`timescale 1ns/1ns

// GPU
// > Built to use an external async memory with multi-channel read/write
// > Assumes that the program is loaded into program memory, data into data memory, and threads into
//   the device control register before the start signal is triggered
// > Has memory controllers to interface between external memory and its multiple cores
// > Configurable number of cores and thread capacity per core
// > Multi-channel memory buses are flattened: channel i occupies bits [WIDTH*i +: WIDTH]
module gpu #(
    parameter DATA_MEM_ADDR_BITS = 8,        // Number of bits in data memory address (256 rows)
    parameter DATA_MEM_DATA_BITS = 8,        // Number of bits in data memory value (8 bit data)
    parameter DATA_MEM_NUM_CHANNELS = 4,     // Number of concurrent channels for sending requests to data memory
    parameter PROGRAM_MEM_ADDR_BITS = 8,     // Number of bits in program memory address (256 rows)
    parameter PROGRAM_MEM_DATA_BITS = 16,    // Number of bits in program memory value (16 bit instruction)
    parameter PROGRAM_MEM_NUM_CHANNELS = 1,  // Number of concurrent channels for sending requests to program memory
    parameter NUM_CORES = 2,                 // Number of cores to include in this GPU
    parameter THREADS_PER_BLOCK = 4          // Number of threads to handle per block (determines the compute resources of each core)
) (
    input wire clk,
    input wire reset,

    // Kernel Execution
    input wire start,
    output wire done,

    // Device Control Register
    input wire device_control_write_enable,
    input wire [7:0] device_control_data,

    // Program Memory
    output wire [PROGRAM_MEM_NUM_CHANNELS-1:0] program_mem_read_valid,
    output wire [PROGRAM_MEM_NUM_CHANNELS*PROGRAM_MEM_ADDR_BITS-1:0] program_mem_read_address,
    input wire [PROGRAM_MEM_NUM_CHANNELS-1:0] program_mem_read_ready,
    input wire [PROGRAM_MEM_NUM_CHANNELS*PROGRAM_MEM_DATA_BITS-1:0] program_mem_read_data,

    // Data Memory
    output wire [DATA_MEM_NUM_CHANNELS-1:0] data_mem_read_valid,
    output wire [DATA_MEM_NUM_CHANNELS*DATA_MEM_ADDR_BITS-1:0] data_mem_read_address,
    input wire [DATA_MEM_NUM_CHANNELS-1:0] data_mem_read_ready,
    input wire [DATA_MEM_NUM_CHANNELS*DATA_MEM_DATA_BITS-1:0] data_mem_read_data,
    output wire [DATA_MEM_NUM_CHANNELS-1:0] data_mem_write_valid,
    output wire [DATA_MEM_NUM_CHANNELS*DATA_MEM_ADDR_BITS-1:0] data_mem_write_address,
    output wire [DATA_MEM_NUM_CHANNELS*DATA_MEM_DATA_BITS-1:0] data_mem_write_data,
    input wire [DATA_MEM_NUM_CHANNELS-1:0] data_mem_write_ready
);
    localparam NUM_LSUS = NUM_CORES * THREADS_PER_BLOCK;
    localparam NUM_FETCHERS = NUM_CORES;
    localparam THREAD_COUNT_BITS = $clog2(THREADS_PER_BLOCK) + 1;

    // Control
    wire [7:0] thread_count;

    // Compute Core State
    wire [NUM_CORES-1:0] core_start;
    wire [NUM_CORES-1:0] core_reset;
    wire [NUM_CORES-1:0] core_done;
    wire [NUM_CORES*8-1:0] core_block_id;
    wire [NUM_CORES*THREAD_COUNT_BITS-1:0] core_thread_count;

    // LSU <> Data Memory Controller Channels
    reg [NUM_LSUS-1:0] lsu_read_valid;
    reg [NUM_LSUS*DATA_MEM_ADDR_BITS-1:0] lsu_read_address;
    wire [NUM_LSUS-1:0] lsu_read_ready;
    wire [NUM_LSUS*DATA_MEM_DATA_BITS-1:0] lsu_read_data;
    reg [NUM_LSUS-1:0] lsu_write_valid;
    reg [NUM_LSUS*DATA_MEM_ADDR_BITS-1:0] lsu_write_address;
    reg [NUM_LSUS*DATA_MEM_DATA_BITS-1:0] lsu_write_data;
    wire [NUM_LSUS-1:0] lsu_write_ready;

    // Fetcher <> Program Memory Controller Channels
    wire [NUM_FETCHERS-1:0] fetcher_read_valid;
    wire [NUM_FETCHERS*PROGRAM_MEM_ADDR_BITS-1:0] fetcher_read_address;
    wire [NUM_FETCHERS-1:0] fetcher_read_ready;
    wire [NUM_FETCHERS*PROGRAM_MEM_DATA_BITS-1:0] fetcher_read_data;

    // Device Control Register
    dcr dcr_instance (
        .clk(clk),
        .reset(reset),

        .device_control_write_enable(device_control_write_enable),
        .device_control_data(device_control_data),
        .thread_count(thread_count)
    );

    // Data Memory Controller
    controller #(
        .ADDR_BITS(DATA_MEM_ADDR_BITS),
        .DATA_BITS(DATA_MEM_DATA_BITS),
        .NUM_CONSUMERS(NUM_LSUS),
        .NUM_CHANNELS(DATA_MEM_NUM_CHANNELS)
    ) data_memory_controller (
        .clk(clk),
        .reset(reset),

        .consumer_read_valid(lsu_read_valid),
        .consumer_read_address(lsu_read_address),
        .consumer_read_ready(lsu_read_ready),
        .consumer_read_data(lsu_read_data),
        .consumer_write_valid(lsu_write_valid),
        .consumer_write_address(lsu_write_address),
        .consumer_write_data(lsu_write_data),
        .consumer_write_ready(lsu_write_ready),

        .mem_read_valid(data_mem_read_valid),
        .mem_read_address(data_mem_read_address),
        .mem_read_ready(data_mem_read_ready),
        .mem_read_data(data_mem_read_data),
        .mem_write_valid(data_mem_write_valid),
        .mem_write_address(data_mem_write_address),
        .mem_write_data(data_mem_write_data),
        .mem_write_ready(data_mem_write_ready)
    );

    // Program Memory Controller (read-only: write consumer interface tied off)
    controller #(
        .ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
        .DATA_BITS(PROGRAM_MEM_DATA_BITS),
        .NUM_CONSUMERS(NUM_FETCHERS),
        .NUM_CHANNELS(PROGRAM_MEM_NUM_CHANNELS),
        .WRITE_ENABLE(0)
    ) program_memory_controller (
        .clk(clk),
        .reset(reset),

        .consumer_read_valid(fetcher_read_valid),
        .consumer_read_address(fetcher_read_address),
        .consumer_read_ready(fetcher_read_ready),
        .consumer_read_data(fetcher_read_data),
        .consumer_write_valid({NUM_FETCHERS{1'b0}}),
        .consumer_write_address({(NUM_FETCHERS*PROGRAM_MEM_ADDR_BITS){1'b0}}),
        .consumer_write_data({(NUM_FETCHERS*PROGRAM_MEM_DATA_BITS){1'b0}}),
        .consumer_write_ready(),

        .mem_read_valid(program_mem_read_valid),
        .mem_read_address(program_mem_read_address),
        .mem_read_ready(program_mem_read_ready),
        .mem_read_data(program_mem_read_data),
        .mem_write_valid(),
        .mem_write_address(),
        .mem_write_data(),
        .mem_write_ready({PROGRAM_MEM_NUM_CHANNELS{1'b0}})
    );

    // Dispatcher
    dispatch #(
        .NUM_CORES(NUM_CORES),
        .THREADS_PER_BLOCK(THREADS_PER_BLOCK)
    ) dispatch_instance (
        .clk(clk),
        .reset(reset),
        .start(start),
        .thread_count(thread_count),
        .core_done(core_done),
        .core_start(core_start),
        .core_reset(core_reset),
        .core_block_id(core_block_id),
        .core_thread_count(core_thread_count),
        .done(done)
    );

    // Compute Cores
    genvar i;
    generate
        for (i = 0; i < NUM_CORES; i = i + 1) begin : cores
            // EDA: We create separate signals here to pass to cores because of a requirement
            // by the OpenLane EDA flow (uses Verilog 2005) that prevents slicing the top-level signals
            wire [THREADS_PER_BLOCK-1:0] core_lsu_read_valid;
            wire [THREADS_PER_BLOCK*DATA_MEM_ADDR_BITS-1:0] core_lsu_read_address;
            reg [THREADS_PER_BLOCK-1:0] core_lsu_read_ready;
            reg [THREADS_PER_BLOCK*DATA_MEM_DATA_BITS-1:0] core_lsu_read_data;
            wire [THREADS_PER_BLOCK-1:0] core_lsu_write_valid;
            wire [THREADS_PER_BLOCK*DATA_MEM_ADDR_BITS-1:0] core_lsu_write_address;
            wire [THREADS_PER_BLOCK*DATA_MEM_DATA_BITS-1:0] core_lsu_write_data;
            reg [THREADS_PER_BLOCK-1:0] core_lsu_write_ready;

            // Pass through signals between LSUs and data memory controller
            genvar j;
            for (j = 0; j < THREADS_PER_BLOCK; j = j + 1) begin : lsu_channels
                localparam lsu_index = i * THREADS_PER_BLOCK + j;
                always @(posedge clk) begin
                    lsu_read_valid[lsu_index] <= core_lsu_read_valid[j];
                    lsu_read_address[DATA_MEM_ADDR_BITS*lsu_index +: DATA_MEM_ADDR_BITS] <=
                        core_lsu_read_address[DATA_MEM_ADDR_BITS*j +: DATA_MEM_ADDR_BITS];

                    lsu_write_valid[lsu_index] <= core_lsu_write_valid[j];
                    lsu_write_address[DATA_MEM_ADDR_BITS*lsu_index +: DATA_MEM_ADDR_BITS] <=
                        core_lsu_write_address[DATA_MEM_ADDR_BITS*j +: DATA_MEM_ADDR_BITS];
                    lsu_write_data[DATA_MEM_DATA_BITS*lsu_index +: DATA_MEM_DATA_BITS] <=
                        core_lsu_write_data[DATA_MEM_DATA_BITS*j +: DATA_MEM_DATA_BITS];

                    core_lsu_read_ready[j] <= lsu_read_ready[lsu_index];
                    core_lsu_read_data[DATA_MEM_DATA_BITS*j +: DATA_MEM_DATA_BITS] <=
                        lsu_read_data[DATA_MEM_DATA_BITS*lsu_index +: DATA_MEM_DATA_BITS];
                    core_lsu_write_ready[j] <= lsu_write_ready[lsu_index];
                end
            end

            // Compute Core
            core #(
                .DATA_MEM_ADDR_BITS(DATA_MEM_ADDR_BITS),
                .DATA_MEM_DATA_BITS(DATA_MEM_DATA_BITS),
                .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
                .PROGRAM_MEM_DATA_BITS(PROGRAM_MEM_DATA_BITS),
                .THREADS_PER_BLOCK(THREADS_PER_BLOCK)
            ) core_instance (
                .clk(clk),
                .reset(core_reset[i]),
                .start(core_start[i]),
                .done(core_done[i]),
                .block_id(core_block_id[8*i +: 8]),
                .thread_count(core_thread_count[THREAD_COUNT_BITS*i +: THREAD_COUNT_BITS]),

                .program_mem_read_valid(fetcher_read_valid[i]),
                .program_mem_read_address(fetcher_read_address[PROGRAM_MEM_ADDR_BITS*i +: PROGRAM_MEM_ADDR_BITS]),
                .program_mem_read_ready(fetcher_read_ready[i]),
                .program_mem_read_data(fetcher_read_data[PROGRAM_MEM_DATA_BITS*i +: PROGRAM_MEM_DATA_BITS]),

                .data_mem_read_valid(core_lsu_read_valid),
                .data_mem_read_address(core_lsu_read_address),
                .data_mem_read_ready(core_lsu_read_ready),
                .data_mem_read_data(core_lsu_read_data),
                .data_mem_write_valid(core_lsu_write_valid),
                .data_mem_write_address(core_lsu_write_address),
                .data_mem_write_data(core_lsu_write_data),
                .data_mem_write_ready(core_lsu_write_ready)
            );
        end
    endgenerate
endmodule
