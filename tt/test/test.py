# cocotb test for tt_um_tiny_gpu -- drives the byte-serial host protocol to load
# the matrix-add kernel + inputs, run the GPU, and check C[i] = A[i] + B[i].
# Ported from tt/tb_tt_um_tiny_gpu.v. Run with `make` (see Makefile).

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, FallingEdge

# host protocol modes (must match tt_um_tiny_gpu.v)
IDLE, LOAD_PROG, LOAD_DATA, SET_THREADS, START, READ_DATA, RESET_PTR = range(7)

# 13-word matrix-add kernel
PROGRAM = [
    0b0101000011011110,  # MUL   R0, %blockIdx, %blockDim
    0b0011000000001111,  # ADD   R0, R0, %threadIdx
    0b1001000100000000,  # CONST R1, #0   (baseA)
    0b1001001000001000,  # CONST R2, #8   (baseB)
    0b1001001100010000,  # CONST R3, #16  (baseC)
    0b0011010000010000,  # ADD   R4, R1, R0
    0b0111010001000000,  # LDR   R4, R4
    0b0011010100100000,  # ADD   R5, R2, R0
    0b0111010101010000,  # LDR   R5, R5
    0b0011011001000101,  # ADD   R6, R4, R5
    0b0011011100110000,  # ADD   R7, R3, R0
    0b1000000001110110,  # STR   R7, R6
    0b1111000000000000,  # RET
]

# A[0..7] = 0..7, B[8..15] = 0..7, C[16..23] = 0
DATA = list(range(8)) + list(range(8)) + [0] * 8
THREADS = 8


async def step(dut, mode, payload=0):
    """Drive one command byte in `mode` for exactly one clock."""
    dut.uio_in.value = mode & 0x07
    dut.ui_in.value = payload & 0xFF
    await ClockCycles(dut.clk, 1)


@cocotb.test()
async def test_matadd(dut):
    dut._log.info("start")
    cocotb.start_soon(Clock(dut.clk, 10, units="us").start())

    # reset
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 4)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 1)

    await step(dut, RESET_PTR)

    # load program: high byte then low byte of each 16-bit word
    for word in PROGRAM:
        await step(dut, LOAD_PROG, (word >> 8) & 0xFF)
        await step(dut, LOAD_PROG, word & 0xFF)

    # load data memory sequentially from address 0
    for byte in DATA:
        await step(dut, LOAD_DATA, byte)

    await step(dut, SET_THREADS, THREADS)
    await step(dut, START)

    # idle-poll done on uo_out[0]
    dut.uio_in.value = IDLE
    dut.ui_in.value = 0
    done = False
    for cycle in range(100000):
        await ClockCycles(dut.clk, 1)
        try:
            done_bit = int(dut.uo_out.value) & 1   # raises if any X/Z
        except ValueError:
            done_bit = 0
        if done_bit:
            done = True
            break
    assert done, "timed out waiting for done"
    dut._log.info(f"kernel done after {cycle} cycles")

    # read results back over READ_DATA (uo_out = data_memory[read_ptr])
    await step(dut, RESET_PTR)
    dut.uio_in.value = READ_DATA
    dut.ui_in.value = 0
    mem = []
    for _ in range(len(DATA)):
        await FallingEdge(dut.clk)               # read_ptr stable, uo_out = mem[i]
        mem.append(int(dut.uo_out.value) & 0xFF)
        await RisingEdge(dut.clk)                # posedge advances read_ptr

    for i in range(8):
        expected = DATA[i] + DATA[i + 8]
        dut._log.info(f"C[{i}] = {mem[16 + i]} (expected {expected})")
        assert mem[16 + i] == expected, \
            f"mismatch at C[{i}]: got {mem[16 + i]}, expected {expected}"

    dut._log.info("PASS: tt_um_tiny_gpu matadd")
