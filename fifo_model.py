"""
Cycle-accurate Python transliteration of sync_fifo.sv.

This mirrors the RTL line-for-line:
  - same pointer width (ADDR_W+1 bits, extra wrap-parity bit)
  - same wr_en_eff / rd_en_eff combinational equations
  - same registered (1-cycle-latency) read data
  - same full/empty equations

It is NOT a substitute for compiling the actual SystemVerilog with
Icarus Verilog. It exists only because no simulator/network is
available in this sandbox. It lets us actually execute the stimulus
and catch real logic bugs (wrong pointer math, wrong full/empty
equations, wrong simultaneous r/w handling) rather than just eyeballing
the code.
"""

class SyncFifoModel:
    def __init__(self, data_width=8, depth=8):
        assert (depth & (depth - 1)) == 0, "DEPTH must be a power of 2"
        self.data_width = data_width
        self.depth = depth
        self.addr_w = depth.bit_length() - 1  # $clog2(depth)
        self.mask = (1 << (self.addr_w + 1)) - 1
        self.addr_mask = depth - 1
        self.reset()

    def reset(self):
        self.mem = [0] * self.depth
        self.wptr = 0
        self.rptr = 0
        self.rdata = 0
        # combinational outputs, recomputed after reset too
        self._update_flags()

    def _update_flags(self):
        wptr, rptr, addr_w = self.wptr, self.rptr, self.addr_w
        self.empty = (wptr == rptr)
        self.full = ((wptr >> addr_w) & 1) != ((rptr >> addr_w) & 1) and \
                    (wptr & self.addr_mask) == (rptr & self.addr_mask)

    def step(self, wr_en, wdata, rd_en):
        """One clock edge, mirroring the two always_ff blocks + combo logic.

        IMPORTANT: the two always_ff blocks in the RTL both use
        NONBLOCKING assignments. Verilog's scheduling semantics say all
        RHS expressions in a time step are evaluated against the
        *pre-edge* state, and only afterwards are all LHS updates
        committed together. In particular `rdata <= mem[rptr]` reads
        the OLD contents of mem[rptr] even if the write-port always_ff
        block is, in the same cycle, doing a nonblocking write to that
        same memory word -- the read does NOT see the write that is
        landing in the same edge. This matters exactly in the
        full+simultaneous-read/write case, where wptr and rptr address
        the *same* memory word (that's what "full" means: same address,
        different wrap bit). Get this ordering wrong in a model (e.g.
        by mutating state sequentially instead of computing next-state
        from a frozen snapshot) and you'll see a false rdata mismatch
        that doesn't exist in the real hardware/simulator.
        """
        wr_en_eff = wr_en and (not self.full or rd_en)
        rd_en_eff = rd_en and (not self.empty)

        # --- evaluate all RHS values from the frozen pre-edge state ---
        rdata_next = self.rdata
        if rd_en_eff:
            rdata_next = self.mem[self.rptr & self.addr_mask]  # OLD mem, OLD rptr

        wptr_next = self.wptr
        write_addr = self.wptr & self.addr_mask
        write_val = wdata & ((1 << self.data_width) - 1)
        if wr_en_eff:
            wptr_next = (self.wptr + 1) & self.mask

        rptr_next = self.rptr
        if rd_en_eff:
            rptr_next = (self.rptr + 1) & self.mask

        # --- commit all updates together (mirrors nonblocking commit) ---
        if wr_en_eff:
            self.mem[write_addr] = write_val
        self.wptr = wptr_next
        self.rptr = rptr_next
        self.rdata = rdata_next

        # full/empty recomputed combinationally from the *new* pointers,
        # exactly like the `assign` statements in the RTL.
        self._update_flags()
        return wr_en_eff, rd_en_eff
