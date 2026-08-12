# Parameterized Synchronous FIFO (SystemVerilog)

A small, single-clock-domain FIFO with a self-checking SystemVerilog
testbench, built as an RTL/verification portfolio project.

## Files

| File               | Purpose                                              |
|--------------------|-------------------------------------------------------|
| `sync_fifo.sv`     | The FIFO RTL (design under test)                       |
| `tb_sync_fifo.sv`  | Self-checking testbench with a reference-model scoreboard |
| `Makefile`         | Compiles and runs the sim with Icarus Verilog          |

## Architecture

### Ports

```
sync_fifo #(.DATA_WIDTH(8), .DEPTH(8)) dut (
    .clk    (clk),
    .rst_n  (rst_n),   // async active-low reset
    .wr_en  (wr_en),
    .wdata  (wdata),
    .rd_en  (rd_en),
    .rdata  (rdata),   // registered, 1 cycle of read latency
    .full   (full),
    .empty  (empty)
);
```

`DEPTH` must be a power of 2 -- the full/empty logic below depends on it.

### Pointers and full/empty detection

The FIFO uses a write pointer (`wptr`) and read pointer (`rptr`), each one
bit **wider** than needed to address the memory (`ADDR_W = $clog2(DEPTH)`,
pointer width = `ADDR_W + 1`).

- The lower `ADDR_W` bits of each pointer are the actual memory address.
- The extra top bit is a "wrap parity" bit: it flips every time the
  pointer wraps around the end of the memory.

This solves the classic FIFO ambiguity: after `wptr == rptr` (empty) or
after the write pointer has lapped the read pointer exactly once (full),
the **low bits alone are identical in both cases**. The extra bit
disambiguates them:

- `empty = (wptr == rptr)` -- pointers fully match, including the wrap bit.
- `full  = (wptr[ADDR_W] != rptr[ADDR_W]) && (wptr[ADDR_W-1:0] == rptr[ADDR_W-1:0])`
  -- same address, but the write pointer has wrapped one more time than
  the read pointer.

This is a purely combinational, single-clock-domain version of the
technique. (Multi-clock-domain / CDC FIFOs use Gray-coded pointers instead
of binary ones so that only one bit changes per clock, which is safe to
synchronize across domains -- not needed here since there's only one
clock.)

### Simultaneous read/write handling

A write while full, or a read while empty, is normally illegal and must
be safely dropped rather than corrupting state. But if a read and write
happen **in the same cycle**, the read frees a slot at the same instant
the write wants to use one -- so that specific combination should be
allowed even when the FIFO started the cycle full (and symmetrically,
a write should be allowed to make data available even if the FIFO started
the cycle empty and something also tried to read from it).

```systemverilog
assign wr_en_eff = wr_en && (!full || rd_en);
assign rd_en_eff = rd_en && !empty;
```

`wr_en_eff`/`rd_en_eff` are what actually drive the pointer updates and
memory write, not the raw `wr_en`/`rd_en` inputs.

### Read latency

`rdata` is a registered output: on a cycle where `rd_en_eff` is asserted,
the data read out of `mem[rptr]` appears on `rdata` at the *next* clock
edge, not combinationally in the same cycle. This is the standard
synchronous-FIFO convention (as opposed to a "first-word-fall-through"
FIFO, which shows the front entry combinationally before any read is
even asserted). The testbench accounts for this latency when predicting
expected values.

## Verification strategy

The testbench (`tb_sync_fifo.sv`) is self-checking: it does not eyeball
waveforms, it computes a golden reference model in parallel with the DUT
and flags any mismatch automatically.

**Reference model:** a plain SystemVerilog queue (`logic [DATA_WIDTH-1:0]
ref_q[$]`) that mirrors exactly what a correct FIFO should contain.

**Driver/checker (`step` task):** drives `wr_en`/`rd_en`/`wdata` for one
clock cycle, and for that same cycle:
1. Predicts, from the reference model's *pre-edge* occupancy, whether the
   write and read will actually be accepted (mirroring `wr_en_eff` /
   `rd_en_eff` in the DUT).
2. Predicts the expected `full`/`empty` values from the reference model's
   *post-edge* occupancy (since the DUT's `full`/`empty` are combinational
   functions of the pointers *after* they've updated for this cycle).
3. Predicts the expected `rdata` from the front of the reference queue,
   if a read is accepted.
4. Samples the DUT after the clock edge and compares all three against
   the predictions.
5. Updates the reference model to match.

Using one task for every kind of cycle (write-only, read-only, both,
neither) means the same logic path covers ordinary operation *and* the
full/empty edge cases, instead of having separate, easier-to-get-wrong
bespoke checks for each.

### Test scenarios covered

1. **Reset** -- `empty` asserted, `full` deasserted after reset.
2. **Normal writes + FIFO ordering + normal reads** -- ordering is
   verified implicitly, since each read's expected value comes from the
   reference queue's front; any reordering bug shows up as an `rdata`
   mismatch.
3. **Full condition** -- fill to `DEPTH`, confirm `full`, then attempt an
   overflow write and confirm it's safely dropped (not corrupting state).
4. **Empty condition** -- drain to empty, confirm `empty`, then attempt an
   underflow read and confirm it's safely dropped.
5. **Simultaneous read/write, partially filled.**
6. **Simultaneous read/write while full** -- one entry out, one in, net
   occupancy unchanged, `full` stays asserted.
7. **Simultaneous read/write while empty** -- write succeeds, the read is
   dropped (nothing to read yet).
8. **Pointer wraparound** -- three full fill/drain cycles, to exercise the
   pointer wrap-parity bit multiple times over (this is the case that
   would break if the full/empty comparison were implemented wrong).
9. **Randomized stress test** -- 500 cycles of random `wr_en`/`rd_en`/
   `wdata`, checked against the reference model every cycle.

An `errors`/`checks` counter accumulates across the whole run, and the
final `$display` reports `PASS`/`FAIL` with the totals.

## How to simulate

Requires [Icarus Verilog](http://iverilog.icarus.com/) (`iverilog` +
`vvp`); GTKWave is optional, for viewing the waveform.

```bash
# Ubuntu/Debian
sudo apt install iverilog gtkwave

# from the project directory
make sim      # compiles and runs the testbench, prints PASS/FAIL
make wave     # re-runs (if needed) and opens the .vcd in GTKWave
```

Or run the two `iverilog`/`vvp` steps directly:

```bash
mkdir -p sim
iverilog -g2012 -o sim/fifo_tb.vvp sync_fifo.sv tb_sync_fifo.sv
vvp sim/fifo_tb.vvp
```

Waveforms are dumped to `sim/fifo_wave.vcd` (see the `$dumpfile`/
`$dumpvars` calls at the top of the testbench); open with
`gtkwave sim/fifo_wave.vcd`. Useful signals to look at first: `wptr`,
`rptr`, `full`, `empty`, and `wr_en_eff`/`rd_en_eff` inside the DUT, to
watch the pointers wrap and see the full/empty flags flip exactly when
expected.

## Results

**`tb_sync_fifo.sv` itself has still not been compiled with a real
Verilog simulator** -- neither this environment nor the original one
had `iverilog` installed, and neither has network access to install it.
So I still can't claim `make sim` has been run.

What I *did* do instead: wrote `fifo_model.py`, a cycle-accurate Python
transliteration of `sync_fifo.sv` (same pointer width, same
`wr_en_eff`/`rd_en_eff` equations, same registered-read timing), and
`run_check.py`, which drives it through the exact same 9 scenarios as
`tb_sync_fifo.sv`, checked against the same kind of reference-model
scoreboard. This is **not a substitute for compiling the actual
SystemVerilog** -- it can't catch SV syntax errors, and it's a second,
independent implementation rather than a proof the two are identical.
But it does actually execute the design's logic against real stimulus,
including a 500-cycle randomized stress test run across 5 different
seeds (2500 random cycles total), and it did catch a real timing issue
worth knowing about (see below) -- so it's meaningfully more than
"read the code and it looks right."

```
======================================================
 sync_fifo logic check (DATA_WIDTH=8 DEPTH=8)
======================================================
[TEST] Reset
[TEST] Normal writes, ordering, normal reads
[TEST] Full condition
[TEST] Empty condition
[TEST] Simultaneous read/write (partial fill)
[TEST] Simultaneous read/write while full
[TEST] Simultaneous read/write while empty
[TEST] Pointer wraparound (boundary case)
[TEST] Randomized stress (500 cycles x 5 seeds)
======================================================
 RESULT: PASS  (3806 checks, 0 errors)
======================================================
```

### A real gotcha this caught

My first pass at `fifo_model.py` updated state sequentially (process
the write, *then* process the read) and got a false failure on
"simultaneous read/write while full": it returned the just-written
value on a read that should have returned the old front-of-queue value.

The bug was in my model, not the RTL -- but it's exactly the kind of
mistake this design invites. When the FIFO is full, `wptr` and `rptr`
point at the *same* memory address (that's the definition of full in
this scheme: same low bits, different wrap-parity bit). So a
simultaneous read+write touches the same word in the same cycle. Real
Verilog's nonblocking-assignment scheduling evaluates every `always_ff`
block's right-hand side against the *pre-edge* state before any of them
commit -- so `rdata <= mem[rptr]` reads the old contents, unaffected by
`mem[wptr] <= wdata` landing in the same edge, even though `wptr` and
`rptr` alias to the same address. `sync_fifo.sv` relies on this
correctly (two separate `always_ff` blocks, each just doing its own
nonblocking read/write). Once I fixed the model to freeze state, compute
next-values, then commit atomically -- matching that scheduling
semantics -- the false failure went away.

**Action for you:** run `make sim` yourself once you have Icarus
Verilog (`sudo apt install iverilog gtkwave`, or on a machine with
network access) and confirm it prints `RESULT: PASS`. That is the
actual verification of `sync_fifo.sv`; everything above is corroborating
evidence, not a replacement for it. `fifo_model.py` / `run_check.py`
are included in this repo if you want to see or rerun the Python check
yourself (`python3 run_check.py`, no dependencies beyond the standard
library).

## Interview talking points

- Why the extra pointer bit is needed for full/empty disambiguation, and
  why Gray coding matters for multi-clock-domain (CDC) FIFOs but not this
  single-clock design.
- The write-while-full-but-reading / read-while-empty-but-writing edge
  case, and why it needs special-casing.
- Registered vs. combinational (fall-through) read data, and the latency
  trade-off.
- Why the testbench predicts `full`/`empty` from *post-edge* occupancy
  but predicts whether a write/read is *accepted* from *pre-edge*
  occupancy -- these are subtly different timing questions and mixing
  them up is an easy self-checking-testbench bug (the project's commit
  history shows this exact bug getting caught and fixed).
- Why a reference-model/scoreboard approach scales better than
  hand-written expected-value tables as test count grows.
- Why, on a simultaneous read+write while full, the read correctly
  returns the *old* data and not the value being written that same
  cycle -- even though `wptr` and `rptr` address the same memory word
  at that point. (Nonblocking-assignment scheduling: every `always_ff`
  block's RHS is evaluated against pre-edge state before any block's
  LHS commits, so the read in one block can't see the write landing
  in another block in the same edge. Get this backwards in a modeling
  or scoreboard context and you'll "prove" a false bug -- see Results.)
