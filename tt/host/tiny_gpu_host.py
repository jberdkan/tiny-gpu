# tiny_gpu_host.py -- MicroPython host driver for tt_um_tiny_gpu on the
# TinyTapeout demo board (RP2040). Loads the matrix-add kernel + inputs over the
# pins, runs the GPU, and reads the results back. Mirrors tb_tt_um_tiny_gpu.v.
#
# Usage: copy onto the TT demo board and run in the REPL, or `import tiny_gpu_host`.
# Requires the ttboard MicroPython SDK that ships with the demo board.

from ttboard.demoboard import DemoBoard, RPMode

# ---- host protocol (must match tt_um_tiny_gpu.v) ----------------------------
IDLE, LOAD_PROG, LOAD_DATA, SET_THREADS, START, READ_DATA, RESET_PTR = range(7)

# 13-word matrix-add kernel (same program as the RTL testbench)
PROGRAM = [
    0b0101000011011110,  # MUL   R0, %blockIdx, %blockDim
    0b0011000000001111,  # ADD   R0, R0, %threadIdx      ; i = bid*bdim + tid
    0b1001000100000000,  # CONST R1, #0                  ; baseA
    0b1001001000001000,  # CONST R2, #8                  ; baseB
    0b1001001100010000,  # CONST R3, #16                 ; baseC
    0b0011010000010000,  # ADD   R4, R1, R0              ; &A[i]
    0b0111010001000000,  # LDR   R4, R4
    0b0011010100100000,  # ADD   R5, R2, R0              ; &B[i]
    0b0111010101010000,  # LDR   R5, R5
    0b0011011001000101,  # ADD   R6, R4, R5              ; A[i]+B[i]
    0b0011011100110000,  # ADD   R7, R3, R0              ; &C[i]
    0b1000000001110110,  # STR   R7, R6
    0b1111000000000000,  # RET
]

# input data memory: A[0..7] = 0..7, B[8..15] = 0..7, C[16..23] = 0
DATA = list(range(8)) + list(range(8)) + [0] * 8
THREADS = 8
RESULT_BASE = 16
RESULT_LEN = 8


def _setup():
    tt = DemoBoard.get()
    tt.shuttle.tt_um_tiny_gpu.enable()      # select this project on the shuttle
    tt.mode = RPMode.ASIC_RP_CONTROL        # RP2040 drives inputs, reads outputs
    tt.clock_project_stopped()              # we clock manually, one edge at a time
    return tt


def _step(tt, mode, payload=0):
    """Drive one command byte in `mode` for exactly one clock."""
    tt.uio_in.value = mode & 0x07
    tt.ui_in.value = payload & 0xFF
    tt.clock_project_once()


def run(tt=None, verbose=True):
    if tt is None:
        tt = _setup()

    # reset: rst_n low, then high
    tt.reset_project(True)
    for _ in range(4):
        tt.clock_project_once()
    tt.reset_project(False)
    tt.clock_project_once()

    _step(tt, RESET_PTR)

    # load program: high byte then low byte of each 16-bit word
    for word in PROGRAM:
        _step(tt, LOAD_PROG, (word >> 8) & 0xFF)
        _step(tt, LOAD_PROG, word & 0xFF)

    # load data memory sequentially from address 0
    for byte in DATA:
        _step(tt, LOAD_DATA, byte)

    _step(tt, SET_THREADS, THREADS)
    _step(tt, START)

    # idle-poll done on uo_out[0]
    tt.uio_in.value = IDLE
    tt.ui_in.value = 0
    done = False
    for cycle in range(100000):
        tt.clock_project_once()
        if tt.uo_out.value & 0x01:
            done = True
            break
    if not done:
        raise RuntimeError("timed out waiting for done")
    if verbose:
        print("kernel done after {} cycles".format(cycle))

    # read results: RESET_PTR then stream bytes out on uo_out
    _step(tt, RESET_PTR)
    tt.uio_in.value = READ_DATA
    tt.ui_in.value = 0
    mem = []
    for _ in range(RESULT_BASE + RESULT_LEN):
        mem.append(tt.uo_out.value & 0xFF)   # uo_out = data_memory[read_ptr]
        tt.clock_project_once()              # advance read_ptr

    results = mem[RESULT_BASE:RESULT_BASE + RESULT_LEN]
    if verbose:
        ok = True
        for i in range(RESULT_LEN):
            exp = DATA[i] + DATA[i + 8]
            mark = "" if results[i] == exp else "  <-- MISMATCH (exp {})".format(exp)
            if results[i] != exp:
                ok = False
            print("C[{}] = {}{}".format(i, results[i], mark))
        print("PASS" if ok else "FAIL")
    return results


if __name__ == "__main__":
    run()
