// =============================================================================
// tb_sync_fifo.sv
// Self-checking testbench for sync_fifo.
// Uses an independent SystemVerilog queue as a golden reference model.
// =============================================================================
`timescale 1ns/1ps

module tb_sync_fifo;

    localparam int DATA_WIDTH = 8;
    localparam int DEPTH      = 8;

    logic                  clk;
    logic                  rst_n;
    logic                  wr_en, rd_en;
    logic [DATA_WIDTH-1:0] wdata, rdata;
    logic                  full, empty;

    int errors = 0;
    int checks = 0;

    sync_fifo #(
        .DATA_WIDTH(DATA_WIDTH),
        .DEPTH(DEPTH)
    ) dut (
        .clk    (clk),
        .rst_n  (rst_n),
        .wr_en  (wr_en),
        .wdata  (wdata),
        .rd_en  (rd_en),
        .rdata  (rdata),
        .full   (full),
        .empty  (empty)
    );

    // 100MHz clock
    initial clk = 0;
    always #5 clk = ~clk;

    // waveform dump
    initial begin
        $dumpfile("sim/fifo_wave.vcd");
        $dumpvars(0, tb_sync_fifo);
    end

    // -------------------------------------------------------------------
    // Golden reference model: a simple SW queue that should always mirror
    // exactly what a correct FIFO contains.
    // -------------------------------------------------------------------
    logic [DATA_WIDTH-1:0] ref_q[$];

    task automatic do_reset();
        rst_n = 0; wr_en = 0; rd_en = 0; wdata = '0;
        repeat (3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        ref_q.delete();
    endtask

    // Drives wr_en/rd_en for exactly one clock, checks full/empty/rdata
    // against the reference model, then updates the reference model.
    // This single task is reused for normal writes, normal reads, AND
    // simultaneous read+write -- the same predicted-then-checked pattern
    // covers all three, including the full/empty edge cases.
    task automatic step(input logic w_en, input logic [DATA_WIDTH-1:0] w_data, input logic r_en);
        logic pre_full, pre_empty, do_w, do_r;
        logic [DATA_WIDTH-1:0] expected_rdata;
        int post_size;
        logic exp_full_post, exp_empty_post;

        @(negedge clk);
        wr_en = w_en;
        wdata = w_data;
        rd_en = r_en;

        // Decide whether the write/read actually happens using the
        // reference model's state *before* this edge -- this mirrors
        // wr_en_eff/rd_en_eff in the DUT, which are combinationally
        // derived from the pointers as registered before this edge.
        pre_full  = (ref_q.size() == DEPTH);
        pre_empty = (ref_q.size() == 0);
        do_w = w_en && (!pre_full || r_en);
        do_r = r_en && !pre_empty;
        if (do_r) expected_rdata = ref_q[0];

        // full/empty, however, are sampled from the DUT *after* the edge,
        // once wptr/rptr have already advanced for this cycle. So the
        // correct prediction to compare against is the POST-edge
        // occupancy, not the pre-edge one.
        post_size = ref_q.size() - (do_r ? 1 : 0) + (do_w ? 1 : 0);
        exp_full_post  = (post_size == DEPTH);
        exp_empty_post = (post_size == 0);

        @(posedge clk);
        #1; // let combinational full/empty and the rdata flop settle

        checks++;
        if (full !== exp_full_post) begin
            errors++;
            $error("[%0t] full mismatch: dut=%0b expected=%0b (post-edge size=%0d)", $time, full, exp_full_post, post_size);
        end
        if (empty !== exp_empty_post) begin
            errors++;
            $error("[%0t] empty mismatch: dut=%0b expected=%0b (post-edge size=%0d)", $time, empty, exp_empty_post, post_size);
        end
        if (do_r) begin
            checks++;
            if (rdata !== expected_rdata) begin
                errors++;
                $error("[%0t] rdata mismatch: dut=%0h expected=%0h", $time, rdata, expected_rdata);
            end
        end

        // update reference model to match (order doesn't affect the
        // result since read pops the front and write pushes the back,
        // but pop-then-push mirrors "old data out, new data in")
        if (do_r) ref_q.pop_front();
        if (do_w) ref_q.push_back(w_data);

        wr_en = 0;
        rd_en = 0;
    endtask

    task automatic check(input bit cond, input string msg);
        checks++;
        if (!cond) begin
            errors++;
            $error("[%0t] %s", $time, msg);
        end
    endtask

    // -------------------------------------------------------------------
    // Test sequence
    // -------------------------------------------------------------------
    initial begin
        logic [DATA_WIDTH-1:0] tmp;

        $display("=========================================================");
        $display(" sync_fifo testbench  (DATA_WIDTH=%0d DEPTH=%0d)", DATA_WIDTH, DEPTH);
        $display("=========================================================");

        // --- 1. Reset behavior -----------------------------------------
        $display("[TEST] Reset");
        do_reset();
        check(empty === 1'b1, "after reset: empty should be 1");
        check(full  === 1'b0, "after reset: full should be 0");

        // --- 2. Normal writes + FIFO ordering + normal reads -----------
        // (ordering is verified implicitly: step() predicts each read's
        //  expected value from the reference queue's *front*, so any
        //  reordering bug would show up as an rdata mismatch)
        $display("[TEST] Normal writes, ordering, normal reads");
        for (int i = 0; i < 4; i++) step(1, 8'hA0 + i, 0); // write A0,A1,A2,A3
        for (int i = 0; i < 4; i++) step(0, 8'h00, 1);     // read them back in order
        check(empty === 1'b1, "queue should be empty after draining what we wrote");

        // --- 3. Full condition ------------------------------------------
        $display("[TEST] Full condition");
        do_reset();
        for (int i = 0; i < DEPTH; i++) step(1, 8'hC0 + i, 0);
        check(full === 1'b1, "FIFO should report full after DEPTH writes");
        // Deliberately attempt an overflow write: FIFO must ignore it,
        // not corrupt state. step() already predicts do_w=0 here and
        // will flag an error if the DUT accepted it anyway.
        step(1, 8'hFF, 0);
        check(full === 1'b1, "FIFO should still be full after a rejected overflow write");

        // --- 4. Empty condition ------------------------------------------
        $display("[TEST] Empty condition");
        for (int i = 0; i < DEPTH; i++) step(0, 8'h00, 1); // drain everything
        check(empty === 1'b1, "FIFO should report empty after draining all DEPTH entries");
        // Deliberately attempt an underflow read: must be safely ignored.
        step(0, 8'h00, 1);
        check(empty === 1'b1, "FIFO should still be empty after a rejected underflow read");

        // --- 5. Simultaneous read/write, partially filled ---------------
        $display("[TEST] Simultaneous read/write (partial fill)");
        do_reset();
        step(1, 8'h11, 0);
        step(1, 8'h22, 0);
        step(1, 8'h33, 1); // write 0x33 while reading out 0x11, same cycle

        // --- 6. Simultaneous read/write while FULL -----------------------
        $display("[TEST] Simultaneous read/write while full");
        do_reset();
        for (int i = 0; i < DEPTH; i++) step(1, 8'hD0 + i, 0);
        check(full === 1'b1, "should be full before the full+simultaneous test");
        step(1, 8'hEE, 1); // full: read+write together must be accepted (net occupancy unchanged)
        check(full === 1'b1, "should still be full: one out, one in, net count unchanged");

        // --- 7. Simultaneous read/write while EMPTY -----------------------
        $display("[TEST] Simultaneous read/write while empty");
        do_reset();
        step(1, 8'h55, 1); // empty: write must succeed, read must be dropped (nothing to read)
        check(empty === 1'b0, "one entry should now be present");

        // --- 8. Boundary: wrap the pointers all the way around twice ----
        $display("[TEST] Pointer wraparound (boundary case)");
        do_reset();
        for (int cycle = 0; cycle < 3; cycle++) begin
            for (int i = 0; i < DEPTH; i++) step(1, i[DATA_WIDTH-1:0] + cycle[DATA_WIDTH-1:0]*8'h10, 0);
            check(full === 1'b1, "should be full at end of wraparound fill");
            for (int i = 0; i < DEPTH; i++) step(0, 8'h00, 1);
            check(empty === 1'b1, "should be empty at end of wraparound drain");
        end

        // --- 9. Randomized stress test against the reference model ------
        $display("[TEST] Randomized stress (500 cycles)");
        do_reset();
        for (int i = 0; i < 500; i++) begin
            bit w, r;
            logic [DATA_WIDTH-1:0] d;
            w = $urandom_range(0, 1);
            r = $urandom_range(0, 1);
            d = $urandom_range(0, 255);
            step(w, d, r);
        end

        // --- Summary ------------------------------------------------------
        $display("=========================================================");
        if (errors == 0)
            $display(" RESULT: PASS  (%0d checks, 0 errors)", checks);
        else
            $display(" RESULT: FAIL  (%0d checks, %0d errors)", checks, errors);
        $display("=========================================================");

        $finish;
    end

    // Safety timeout in case something hangs
    initial begin
        #200000;
        $display("ERROR: testbench timeout - simulation did not finish");
        $finish;
    end

endmodule
