"""
Runs the SAME scenarios as tb_sync_fifo.sv, against the SAME kind of
golden reference-model scoreboard (a plain Python list acting as a
queue), driving fifo_model.SyncFifoModel instead of the real DUT.

This exists only as a stand-in because Icarus Verilog isn't
installable in this sandbox (no network). It checks the *logic*, not
the SystemVerilog syntax -- see README for that caveat.
"""
import random
from fifo_model import SyncFifoModel

DATA_WIDTH = 8
DEPTH = 8

errors = 0
checks = 0
ref_q = []


def do_reset(dut):
    dut.reset()
    ref_q.clear()


def step(dut, w_en, w_data, r_en):
    global errors, checks
    pre_full = (len(ref_q) == DEPTH)
    pre_empty = (len(ref_q) == 0)
    do_w = bool(w_en) and (not pre_full or r_en)
    do_r = bool(r_en) and not pre_empty
    expected_rdata = ref_q[0] if do_r else None

    post_size = len(ref_q) - (1 if do_r else 0) + (1 if do_w else 0)
    exp_full_post = (post_size == DEPTH)
    exp_empty_post = (post_size == 0)

    wr_en_eff, rd_en_eff = dut.step(w_en, w_data, r_en)

    checks += 1
    if dut.full != exp_full_post:
        errors += 1
        print(f"  ERROR full mismatch: dut={dut.full} expected={exp_full_post} (post_size={post_size})")
    if dut.empty != exp_empty_post:
        errors += 1
        print(f"  ERROR empty mismatch: dut={dut.empty} expected={exp_empty_post} (post_size={post_size})")
    if do_r:
        checks += 1
        if dut.rdata != expected_rdata:
            errors += 1
            print(f"  ERROR rdata mismatch: dut={dut.rdata:#04x} expected={expected_rdata:#04x}")

    # also cross-check effective enables against the RTL's own outputs
    if do_w != wr_en_eff:
        errors += 1
        print(f"  ERROR wr_en_eff mismatch: dut={wr_en_eff} expected={do_w}")
    if do_r != rd_en_eff:
        errors += 1
        print(f"  ERROR rd_en_eff mismatch: dut={rd_en_eff} expected={do_r}")

    if do_r:
        ref_q.pop(0)
    if do_w:
        ref_q.append(w_data & 0xFF)


def check(cond, msg):
    global errors, checks
    checks += 1
    if not cond:
        errors += 1
        print(f"  ERROR: {msg}")


def main():
    global errors, checks
    dut = SyncFifoModel(DATA_WIDTH, DEPTH)

    print("=" * 60)
    print(f" sync_fifo logic check (DATA_WIDTH={DATA_WIDTH} DEPTH={DEPTH})")
    print("=" * 60)

    print("[TEST] Reset")
    do_reset(dut)
    check(dut.empty is True, "after reset: empty should be 1")
    check(dut.full is False, "after reset: full should be 0")

    print("[TEST] Normal writes, ordering, normal reads")
    for i in range(4):
        step(dut, 1, 0xA0 + i, 0)
    for i in range(4):
        step(dut, 0, 0x00, 1)
    check(dut.empty is True, "queue should be empty after draining what we wrote")

    print("[TEST] Full condition")
    do_reset(dut)
    for i in range(DEPTH):
        step(dut, 1, 0xC0 + i, 0)
    check(dut.full is True, "FIFO should report full after DEPTH writes")
    step(dut, 1, 0xFF, 0)  # overflow write, must be dropped
    check(dut.full is True, "FIFO should still be full after a rejected overflow write")

    print("[TEST] Empty condition")
    for i in range(DEPTH):
        step(dut, 0, 0x00, 1)
    check(dut.empty is True, "FIFO should report empty after draining all DEPTH entries")
    step(dut, 0, 0x00, 1)  # underflow read, must be dropped
    check(dut.empty is True, "FIFO should still be empty after a rejected underflow read")

    print("[TEST] Simultaneous read/write (partial fill)")
    do_reset(dut)
    step(dut, 1, 0x11, 0)
    step(dut, 1, 0x22, 0)
    step(dut, 1, 0x33, 1)

    print("[TEST] Simultaneous read/write while full")
    do_reset(dut)
    for i in range(DEPTH):
        step(dut, 1, 0xD0 + i, 0)
    check(dut.full is True, "should be full before the full+simultaneous test")
    step(dut, 1, 0xEE, 1)
    check(dut.full is True, "should still be full: one out, one in, net count unchanged")

    print("[TEST] Simultaneous read/write while empty")
    do_reset(dut)
    step(dut, 1, 0x55, 1)
    check(dut.empty is False, "one entry should now be present")

    print("[TEST] Pointer wraparound (boundary case)")
    do_reset(dut)
    for cyc in range(3):
        for i in range(DEPTH):
            step(dut, 1, (i + cyc * 0x10) & 0xFF, 0)
        check(dut.full is True, "should be full at end of wraparound fill")
        for i in range(DEPTH):
            step(dut, 0, 0x00, 1)
        check(dut.empty is True, "should be empty at end of wraparound drain")

    print("[TEST] Randomized stress (500 cycles x 5 seeds)")
    for seed in range(5):
        rng = random.Random(seed)
        do_reset(dut)
        for _ in range(500):
            w = rng.randint(0, 1)
            r = rng.randint(0, 1)
            d = rng.randint(0, 255)
            step(dut, w, d, r)

    print("=" * 60)
    if errors == 0:
        print(f" RESULT: PASS  ({checks} checks, 0 errors)")
    else:
        print(f" RESULT: FAIL  ({checks} checks, {errors} errors)")
    print("=" * 60)
    return errors


if __name__ == "__main__":
    raise SystemExit(1 if main() != 0 else 0)
