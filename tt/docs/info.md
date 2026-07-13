<!---
This file is the project documentation shown on the TinyTapeout project page.
-->

## How it works

This is [tiny-gpu](https://github.com/adam-maj/tiny-gpu) — a minimal general-purpose
GPU — shrunk to fit a TinyTapeout tile and wrapped so it needs no external memory.

The core is a SIMT machine: a dispatcher hands blocks of threads to a compute
core, each thread has its own ALU, LSU, register file and PC, and two memory
controllers arbitrate access to program and data memory. For TinyTapeout it is
configured as **1 core / 2 threads / 2 data channels**, and the ALU divider is
removed (`NO_DIV`) to save area — the demo kernels only add and multiply.

Because TinyTapeout gives every project just 8 in / 8 out / 8 bidirectional
pins, the wrapper (`tt_um_tiny_gpu`) puts small **program and data memories on
chip** (16 instruction words, 32 data bytes) and adds a **byte-per-clock host
protocol** so a microcontroller can load a program, load input data, run the
kernel, and read the results back — all over those pins.

### Pin interface

| Signal | Direction | Function |
|--------|-----------|----------|
| `ui[7:0]`  | input  | payload byte from the host (program / data / thread count) |
| `uo[7:0]`  | output | result byte during `READ_DATA`; otherwise `{7'b0, done}` |
| `uio[2:0]` | input  | **mode** (see below) |
| `uio[7:3]` | input  | unused |

The `uio` pins are always inputs (`uio_oe = 0`); the design never drives them.

### Modes (`uio[2:0]`)

TinyTapeout drives the clock, so exactly one byte is consumed per clock while a
mode is held.

| Mode | Value | Action |
|------|-------|--------|
| `IDLE`        | 0 | do nothing; `uo_out = {7'b0, done}` |
| `LOAD_PROG`   | 1 | stream program bytes, **MSB first**, 2 bytes = 1 instruction word |
| `LOAD_DATA`   | 2 | stream data-memory bytes sequentially from address 0 |
| `SET_THREADS` | 3 | latch `ui_in` as the total thread count |
| `START`       | 4 | launch the kernel |
| `READ_DATA`   | 5 | `uo_out = data_memory[read_ptr]`, pointer auto-increments |
| `RESET_PTR`   | 6 | reset all load/read pointers to 0 |

## How to test

1. Assert `rst_n` low, then high.
2. `RESET_PTR` (1 clock).
3. `LOAD_PROG`: stream the kernel, high byte then low byte of each 16-bit word.
4. `LOAD_DATA`: stream the input bytes (address auto-increments from 0).
5. `SET_THREADS`: present the total thread count on `ui_in` (1 clock).
6. `START` (1 clock), then hold `IDLE` and poll `uo_out[0]` until it reads 1 (done).
7. `RESET_PTR`, then `READ_DATA` and read `uo_out` on each clock to stream the
   results out.

The included **matrix-add** demo loads a 13-instruction kernel and two 8-element
vectors A and B, runs it, and the result `C[i] = A[i] + B[i]` appears in data
memory at addresses 16..23.

A ready-to-run host script for the TinyTapeout demo board is in
[`host/tiny_gpu_host.py`](host/tiny_gpu_host.py), and the RTL testbench that
drives the exact same protocol is `tb_tt_um_tiny_gpu.v`.

## External hardware

None. The design is self-contained — the host is the TinyTapeout demo board's
on-board microcontroller (RP2040), which drives the pins per the protocol above.
