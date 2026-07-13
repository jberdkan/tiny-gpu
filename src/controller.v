`default_nettype none
`timescale 1ns/1ns

// MEMORY CONTROLLER
// > Receives memory requests from all cores
// > Throttles requests based on limited external memory bandwidth
// > Waits for responses from external memory and distributes them back to cores
// > Multi-element buses are flattened: consumer/channel i occupies bits [WIDTH*i +: WIDTH]
module controller #(
    parameter ADDR_BITS = 8,
    parameter DATA_BITS = 16,
    parameter NUM_CONSUMERS = 4, // The number of consumers accessing memory through this controller
    parameter NUM_CHANNELS = 1,  // The number of concurrent channels available to send requests to global memory
    parameter WRITE_ENABLE = 1   // Whether this memory controller can write to memory (program memory is read-only)
) (
    input wire clk,
    input wire reset,

    // Consumer Interface (Fetchers / LSUs)
    input wire [NUM_CONSUMERS-1:0] consumer_read_valid,
    input wire [NUM_CONSUMERS*ADDR_BITS-1:0] consumer_read_address,
    output reg [NUM_CONSUMERS-1:0] consumer_read_ready,
    output reg [NUM_CONSUMERS*DATA_BITS-1:0] consumer_read_data,
    input wire [NUM_CONSUMERS-1:0] consumer_write_valid,
    input wire [NUM_CONSUMERS*ADDR_BITS-1:0] consumer_write_address,
    input wire [NUM_CONSUMERS*DATA_BITS-1:0] consumer_write_data,
    output reg [NUM_CONSUMERS-1:0] consumer_write_ready,

    // Memory Interface (Data / Program)
    output reg [NUM_CHANNELS-1:0] mem_read_valid,
    output reg [NUM_CHANNELS*ADDR_BITS-1:0] mem_read_address,
    input wire [NUM_CHANNELS-1:0] mem_read_ready,
    input wire [NUM_CHANNELS*DATA_BITS-1:0] mem_read_data,
    output reg [NUM_CHANNELS-1:0] mem_write_valid,
    output reg [NUM_CHANNELS*ADDR_BITS-1:0] mem_write_address,
    output reg [NUM_CHANNELS*DATA_BITS-1:0] mem_write_data,
    input wire [NUM_CHANNELS-1:0] mem_write_ready
);
    localparam IDLE = 3'b000,
        READ_WAITING = 3'b010,
        WRITE_WAITING = 3'b011,
        READ_RELAYING = 3'b100,
        WRITE_RELAYING = 3'b101;

    // Keep track of state for each channel and which jobs each channel is handling
    reg [2:0] controller_state [NUM_CHANNELS-1:0];
    reg [$clog2(NUM_CONSUMERS)-1:0] current_consumer [NUM_CHANNELS-1:0]; // Which consumer is each channel currently serving
    reg [NUM_CONSUMERS-1:0] channel_serving_consumer; // Which channels are being served? Prevents many workers from picking up the same request.

    reg request_pending; // Set once a channel picks up a request (replaces the SV `break`)
    // Plain-reg copy of current_consumer[i], used only as a read-index / compare.
    // NOTE (Yosys): we must never *write* to a reg at a variable index
    // (consumer_*[cc], consumer_read_data[DATA_BITS*cc +:..]) - Yosys leaves the
    // computed "$bitselwrite$pos" undriven (238 synth-check errors). Instead we
    // loop k over the consumers and write only the slice where (cc == k); k is a
    // loop variable that unrolls to constant indices, which Yosys handles cleanly.
    reg [$clog2(NUM_CONSUMERS)-1:0] cc;
    integer i, j, k;

    always @(posedge clk) begin
        if (reset) begin
            mem_read_valid <= 0;
            mem_read_address <= 0;

            mem_write_valid <= 0;
            mem_write_address <= 0;
            mem_write_data <= 0;

            consumer_read_ready <= 0;
            consumer_read_data <= 0;
            consumer_write_ready <= 0;

            for (i = 0; i < NUM_CHANNELS; i = i + 1) begin
                current_consumer[i] <= 0;
                controller_state[i] <= 0;
            end

            channel_serving_consumer = 0;
        end else begin
            // For each channel, we handle processing concurrently
            for (i = 0; i < NUM_CHANNELS; i = i + 1) begin
                // Read the channel's current consumer into a plain reg so the
                // indexed part-select writes below get a proper driver (Yosys).
                cc = current_consumer[i];
                case (controller_state[i])
                    IDLE: begin
                        // While this channel is idle, cycle through consumers looking for one with a pending request
                        request_pending = 0;
                        for (j = 0; j < NUM_CONSUMERS; j = j + 1) begin
                            // Once we find a pending request, pick it up with this channel and stop looking for requests
                            if (!request_pending) begin
                                if (consumer_read_valid[j] && !channel_serving_consumer[j]) begin
                                    request_pending = 1;
                                    channel_serving_consumer[j] = 1;
                                    current_consumer[i] <= j;

                                    mem_read_valid[i] <= 1;
                                    mem_read_address[ADDR_BITS*i +: ADDR_BITS] <= consumer_read_address[ADDR_BITS*j +: ADDR_BITS];
                                    controller_state[i] <= READ_WAITING;
                                end else if (consumer_write_valid[j] && !channel_serving_consumer[j]) begin
                                    request_pending = 1;
                                    channel_serving_consumer[j] = 1;
                                    current_consumer[i] <= j;

                                    mem_write_valid[i] <= 1;
                                    mem_write_address[ADDR_BITS*i +: ADDR_BITS] <= consumer_write_address[ADDR_BITS*j +: ADDR_BITS];
                                    mem_write_data[DATA_BITS*i +: DATA_BITS] <= consumer_write_data[DATA_BITS*j +: DATA_BITS];
                                    controller_state[i] <= WRITE_WAITING;
                                end
                            end
                        end
                    end
                    READ_WAITING: begin
                        // Wait for response from memory for pending read request
                        if (mem_read_ready[i]) begin
                            mem_read_valid[i] <= 0;
                            // write only the served consumer's slice (constant k)
                            for (k = 0; k < NUM_CONSUMERS; k = k + 1) begin
                                if (cc == k) begin
                                    consumer_read_ready[k] <= 1;
                                    consumer_read_data[DATA_BITS*k +: DATA_BITS] <= mem_read_data[DATA_BITS*i +: DATA_BITS];
                                end
                            end
                            controller_state[i] <= READ_RELAYING;
                        end
                    end
                    WRITE_WAITING: begin
                        // Wait for response from memory for pending write request
                        if (mem_write_ready[i]) begin
                            mem_write_valid[i] <= 0;
                            for (k = 0; k < NUM_CONSUMERS; k = k + 1) begin
                                if (cc == k) consumer_write_ready[k] <= 1;
                            end
                            controller_state[i] <= WRITE_RELAYING;
                        end
                    end
                    // Wait until consumer acknowledges it received response, then reset
                    READ_RELAYING: begin
                        if (!consumer_read_valid[cc]) begin
                            for (k = 0; k < NUM_CONSUMERS; k = k + 1) begin
                                if (cc == k) begin
                                    channel_serving_consumer[k] = 0;
                                    consumer_read_ready[k] <= 0;
                                end
                            end
                            controller_state[i] <= IDLE;
                        end
                    end
                    WRITE_RELAYING: begin
                        if (!consumer_write_valid[cc]) begin
                            for (k = 0; k < NUM_CONSUMERS; k = k + 1) begin
                                if (cc == k) begin
                                    channel_serving_consumer[k] = 0;
                                    consumer_write_ready[k] <= 0;
                                end
                            end
                            controller_state[i] <= IDLE;
                        end
                    end
                endcase
            end
        end
    end
endmodule
