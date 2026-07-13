`default_nettype none
`timescale 1ns/1ns

// =============================================================================
// TinyTapeout wrapper for tiny-gpu
// -----------------------------------------------------------------------------
// tiny-gpu normally needs external program/data memory and ~180 I/O pins.
// TinyTapeout gives every project a FIXED 24-signal interface (8 in, 8 out,
// 8 bidir) shared through the TT harness mux. To fit, this wrapper:
//
//   1. Instantiates a SHRUNK gpu (1 core, 4 threads, 2 data channels).
//   2. Puts small program & data memories ON-CHIP so no external mem pins are
//      needed. They speak the same valid/ready handshake the gpu expects.
//   3. Adds a byte-per-clock host protocol on the pins to load the program,
//      load input data, set the thread count, start the kernel, and read the
//      results back out.
//
// Host protocol (TinyTapeout drives the clock, so 1 byte is consumed per clk):
//   uio_in[2:0] = MODE, ui_in[7:0] = payload byte, uo_out[7:0] = output byte
//
//   MODE 0 IDLE        : do nothing;  uo_out = {7'b0, done}
//   MODE 1 LOAD_PROG   : stream program bytes, MSB-first, 2 bytes = 1 instr word
//   MODE 2 LOAD_DATA   : stream data-memory bytes sequentially from address 0
//   MODE 3 SET_THREADS : latch ui_in as the total thread count (device control)
//   MODE 4 START       : launch the kernel (latches, gpu leaves idle)
//   MODE 5 READ_DATA   : uo_out = data_memory[read_ptr], read_ptr auto-increments
//   MODE 6 RESET_PTR   : reset all load/read pointers to 0
//
// Typical sequence a host (e.g. the TT RP2040) runs:
//   rst_n low->high, RESET_PTR, LOAD_PROG (2*Ninstr clks), LOAD_DATA (Nbytes),
//   SET_THREADS (1), START (1), poll IDLE until uo_out[0]=done,
//   RESET_PTR, READ_DATA (Nbytes).
// =============================================================================
module tt_um_tiny_gpu (
    input  wire [7:0] ui_in,    // dedicated inputs  (payload byte from host)
    output wire [7:0] uo_out,   // dedicated outputs (result byte / done flag)
    input  wire [7:0] uio_in,   // bidir inputs      (uio_in[2:0] = mode)
    output wire [7:0] uio_out,  // bidir outputs     (unused, tied low)
    output wire [7:0] uio_oe,   // bidir enables     (all inputs -> 0)
    input  wire       ena,      // high when the design is selected (unused)
    input  wire       clk,
    input  wire       rst_n     // active-low reset
);
    // ---- shrunk gpu configuration (tuned to fit a TinyTapeout tile) ----------
    localparam ADDR_BITS      = 8;   // gpu-internal address width (unchanged)
    localparam DATA_BITS      = 8;   // data-memory word width
    localparam PROG_DATA_BITS = 16;  // instruction width
    localparam DATA_CHANNELS  = 2;   // data-memory channels
    localparam PROG_CHANNELS  = 1;   // program-memory channels
    localparam NUM_CORES      = 1;
    localparam THREADS        = 2;   // threads per block (2 to fit a TT tile;
                                     // the multiplier+divider are per-thread, so
                                     // this roughly halves the core datapath area)

    // ---- on-chip memory depths (dominate area; keep small) -------------------
    // Only the low PROG_AW / DATA_AW bits of the gpu's 8-bit address are
    // decoded, so the memories are tiny while the gpu interface stays 8-bit.
    // Sized just past the matadd demo (13 instrs, data addrs up to 23).
    localparam PROG_WORDS = 16;  localparam PROG_AW = 4;
    localparam DATA_WORDS = 32;  localparam DATA_AW = 5;

    // ---- host protocol modes -------------------------------------------------
    localparam MODE_IDLE = 3'd0, MODE_LOAD_PROG = 3'd1, MODE_LOAD_DATA = 3'd2,
               MODE_SET_THREADS = 3'd3, MODE_START = 3'd4, MODE_READ_DATA = 3'd5,
               MODE_RESET_PTR = 3'd6;

    wire       sys_reset = ~rst_n;
    wire [2:0] mode      = uio_in[2:0];

    // Unused TT signals
    assign uio_out = 8'b0;
    assign uio_oe  = 8'b0;   // uio pins are inputs (host drives the mode)
    wire _unused = &{ena, ui_in[7], uio_in[7:3], 1'b0};

    // ---- gpu <-> wrapper nets ------------------------------------------------
    wire                            done;
    wire [PROG_CHANNELS-1:0]                 program_mem_read_valid;
    wire [PROG_CHANNELS*ADDR_BITS-1:0]       program_mem_read_address;
    wire [DATA_CHANNELS-1:0]                 data_mem_read_valid;
    wire [DATA_CHANNELS*ADDR_BITS-1:0]       data_mem_read_address;
    wire [DATA_CHANNELS-1:0]                 data_mem_write_valid;
    wire [DATA_CHANNELS*ADDR_BITS-1:0]       data_mem_write_address;
    wire [DATA_CHANNELS*DATA_BITS-1:0]       data_mem_write_data;

    // wrapper-driven inputs back into the gpu
    reg  [PROG_CHANNELS-1:0]                 prog_rready_r;
    reg  [PROG_CHANNELS*PROG_DATA_BITS-1:0]  prog_rdata_r;
    reg  [DATA_CHANNELS-1:0]                 data_rready_r;
    reg  [DATA_CHANNELS*DATA_BITS-1:0]       data_rdata_r;
    reg  [DATA_CHANNELS-1:0]                 data_wready_r;

    reg        start_r;
    reg        running;
    reg        dcw_r;          // device_control_write_enable
    reg  [7:0] dcd_r;          // device_control_data (thread count)

    // ---- on-chip memories ----------------------------------------------------
    reg [PROG_DATA_BITS-1:0] program_memory [0:PROG_WORDS-1];
    reg [DATA_BITS-1:0]      data_memory    [0:DATA_WORDS-1];

    // ---- load / service pointers ---------------------------------------------
    reg [PROG_AW-1:0] prog_wr_ptr;
    reg [DATA_AW-1:0] data_wr_ptr;
    reg [DATA_AW-1:0] read_ptr;
    reg               prog_phase;   // 0 = expecting high byte, 1 = low byte
    reg [7:0]         prog_hi;

    integer c;

    // ---- single writer of the memories + gpu memory responses ----------------
    always @(posedge clk) begin
        if (sys_reset) begin
            prog_wr_ptr   <= 0;
            data_wr_ptr   <= 0;
            prog_phase    <= 1'b0;
            prog_hi       <= 8'b0;
            running       <= 1'b0;
            start_r       <= 1'b0;
            dcw_r         <= 1'b0;
            dcd_r         <= 8'b0;
            prog_rready_r <= 0;
            prog_rdata_r  <= 0;
            data_rready_r <= 0;
            data_rdata_r  <= 0;
            data_wready_r <= 0;
        end else begin
            dcw_r <= 1'b0;   // one-cycle strobe by default

            if (!running) begin
                // -------- host load / control phase (gpu idle) ----------------
                prog_rready_r <= 0;
                data_rready_r <= 0;
                data_wready_r <= 0;
                case (mode)
                    MODE_LOAD_PROG: begin
                        if (prog_phase == 1'b0) begin
                            prog_hi    <= ui_in;
                            prog_phase <= 1'b1;
                        end else begin
                            program_memory[prog_wr_ptr] <= {prog_hi, ui_in};
                            prog_wr_ptr <= prog_wr_ptr + 1'b1;
                            prog_phase  <= 1'b0;
                        end
                    end
                    MODE_LOAD_DATA: begin
                        data_memory[data_wr_ptr] <= ui_in;
                        data_wr_ptr <= data_wr_ptr + 1'b1;
                    end
                    MODE_SET_THREADS: begin
                        dcw_r <= 1'b1;
                        dcd_r <= ui_in;
                    end
                    MODE_START: begin
                        running <= 1'b1;
                        start_r <= 1'b1;
                    end
                    MODE_RESET_PTR: begin
                        prog_wr_ptr <= 0;
                        data_wr_ptr <= 0;
                        prog_phase  <= 1'b0;
                    end
                    default: ;
                endcase
            end else begin
                // -------- run phase: answer the gpu's memory requests ---------
                // Program memory (read-only, PROG_CHANNELS = 1)
                if (program_mem_read_valid[0]) begin
                    prog_rdata_r  <= program_memory[program_mem_read_address[PROG_AW-1:0]];
                    prog_rready_r <= 1'b1;
                end else begin
                    prog_rready_r <= 1'b0;
                end

                // Data memory (read + write). c is a loop variable over a
                // constant range, so every indexed part-select below unrolls to
                // a constant index -- Yosys-safe (unlike a data-dependent index).
                for (c = 0; c < DATA_CHANNELS; c = c + 1) begin
                    if (data_mem_read_valid[c]) begin
                        data_rdata_r[DATA_BITS*c +: DATA_BITS] <=
                            data_memory[data_mem_read_address[ADDR_BITS*c +: DATA_AW]];
                        data_rready_r[c] <= 1'b1;
                    end else begin
                        data_rready_r[c] <= 1'b0;
                    end

                    if (data_mem_write_valid[c]) begin
                        data_memory[data_mem_write_address[ADDR_BITS*c +: DATA_AW]] <=
                            data_mem_write_data[DATA_BITS*c +: DATA_BITS];
                        data_wready_r[c] <= 1'b1;
                    end else begin
                        data_wready_r[c] <= 1'b0;
                    end
                end
            end
        end
    end

    // ---- result readout pointer ----------------------------------------------
    always @(posedge clk) begin
        if (sys_reset)
            read_ptr <= 0;
        else if (mode == MODE_RESET_PTR)
            read_ptr <= 0;
        else if (mode == MODE_READ_DATA)
            read_ptr <= read_ptr + 1'b1;
    end

    assign uo_out = (mode == MODE_READ_DATA) ? data_memory[read_ptr]
                                             : {7'b0, done};

    // ---- the (shrunk) gpu ----------------------------------------------------
    gpu #(
        .DATA_MEM_ADDR_BITS(ADDR_BITS),
        .DATA_MEM_DATA_BITS(DATA_BITS),
        .DATA_MEM_NUM_CHANNELS(DATA_CHANNELS),
        .PROGRAM_MEM_ADDR_BITS(ADDR_BITS),
        .PROGRAM_MEM_DATA_BITS(PROG_DATA_BITS),
        .PROGRAM_MEM_NUM_CHANNELS(PROG_CHANNELS),
        .NUM_CORES(NUM_CORES),
        .THREADS_PER_BLOCK(THREADS)
    ) u_gpu (
        .clk(clk),
        .reset(sys_reset),

        .start(start_r),
        .done(done),

        .device_control_write_enable(dcw_r),
        .device_control_data(dcd_r),

        .program_mem_read_valid(program_mem_read_valid),
        .program_mem_read_address(program_mem_read_address),
        .program_mem_read_ready(prog_rready_r),
        .program_mem_read_data(prog_rdata_r),

        .data_mem_read_valid(data_mem_read_valid),
        .data_mem_read_address(data_mem_read_address),
        .data_mem_read_ready(data_rready_r),
        .data_mem_read_data(data_rdata_r),
        .data_mem_write_valid(data_mem_write_valid),
        .data_mem_write_address(data_mem_write_address),
        .data_mem_write_data(data_mem_write_data),
        .data_mem_write_ready(data_wready_r)
    );
endmodule

`default_nettype wire
