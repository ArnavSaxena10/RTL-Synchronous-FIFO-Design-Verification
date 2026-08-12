// =============================================================================
// sync_fifo.sv
// Parameterized synchronous FIFO (single clock domain).
//
// - DATA_WIDTH : width of each entry
// - DEPTH      : number of entries, must be a power of 2 (uses the classic
//                "extra MSB pointer bit" scheme for full/empty detection)
// =============================================================================
`timescale 1ns/1ps

module sync_fifo #(
    parameter int DATA_WIDTH = 8,
    parameter int DEPTH      = 8
) (
    input  logic                  clk,
    input  logic                  rst_n,     // async active-low reset

    input  logic                  wr_en,
    input  logic [DATA_WIDTH-1:0] wdata,

    input  logic                  rd_en,
    output logic [DATA_WIDTH-1:0] rdata,

    output logic                  full,
    output logic                  empty
);

    localparam int ADDR_W = $clog2(DEPTH);

    // Storage
    logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    // Pointers are ADDR_W+1 bits wide: the extra top bit is not a real
    // memory address, it's a "wrap parity" bit. Comparing it lets us tell
    // full apart from empty even though both conditions have wptr==rptr
    // in their lower ADDR_W bits.
    logic [ADDR_W:0] wptr, rptr;

    // Effective enables: a write while full is normally illegal and must
    // be safely dropped -- UNLESS a read is happening in the very same
    // cycle, which frees a slot at the same instant. Symmetric logic for
    // reads while empty.
    logic wr_en_eff, rd_en_eff;
    assign wr_en_eff = wr_en && (!full || rd_en);
    assign rd_en_eff = rd_en && !empty;

    // Write port
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wptr <= '0;
        end else if (wr_en_eff) begin
            mem[wptr[ADDR_W-1:0]] <= wdata;
            wptr <= wptr + 1'b1;
        end
    end

    // Read port (registered output -- one cycle of read latency, standard
    // for a synchronous FIFO)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rptr  <= '0;
            rdata <= '0;
        end else if (rd_en_eff) begin
            rdata <= mem[rptr[ADDR_W-1:0]];
            rptr  <= rptr + 1'b1;
        end
    end

    // Full/empty from pointer comparison:
    //   empty : pointers fully match (including the wrap bit)
    //   full  : lower address bits match but the wrap bit differs
    //           (write pointer has lapped the read pointer exactly once)
    assign empty = (wptr == rptr);
    assign full  = (wptr[ADDR_W]     != rptr[ADDR_W]) &&
                   (wptr[ADDR_W-1:0] == rptr[ADDR_W-1:0]);

endmodule
