`timescale 1ns / 1ps

// Testbench for miniRV with RAM + VGA framebuffer MMIO.
//
// MMIO mapping (from the course doc):
//   [0x2000_0000, 0x2004_0000) : 256x256 framebuffer, 32-bit per pixel.
//
// Plusargs:
//   +HEX=<path>            : required, word-wise hex image for $readmemh
//   +MAX_CYCLES=<N>        : stop after N cycles (default 6000)
//   +TRACE=1               : optional, print per-cycle trace
//   +FBDUMP=<path>         : optional, dump framebuffer hex at finish
module minirv_tb;
  // Keep RAM large enough for official mem/sum/vga stacks and data sections.
  // Use compact RAM with address remap for high stack region.
  parameter MEM_WORDS = 32'd98304;  // default 384 KiB / 4

  localparam FB_WIDTH  = 256;
  localparam FB_HEIGHT = 256;
  localparam FB_WORDS  = FB_WIDTH * FB_HEIGHT;
  localparam FB_BASE   = 32'h2000_0000;
  localparam FB_END    = 32'h2004_0000;

  reg clk;
  reg rstn;

  wire [31:0] pc;
  wire [31:0] reg_a0;
  wire        mem_clk;
  wire [31:0] mem_addr;
  wire [31:0] mem_dataout;
  wire [31:0] mem_datain;
  wire        mem_we;

  reg [31:0] mem [0:MEM_WORDS - 1];
  reg [31:0] mem_dataout_r;

  reg [1023:0] hex_file;
  reg [1023:0] fb_dump_file;
  integer max_cycles;
  integer trace_en;
  integer cycle_cnt;
  integer i;
  integer fb_event_fd;
  integer fb_dump_en;

  wire is_fb_addr = (mem_addr >= FB_BASE) && (mem_addr < FB_END);
  wire [31:0] fb_index = (mem_addr - FB_BASE) >> 2;
  wire [31:0] mem_addr_mapped =
    ((mem_addr >= 32'h0009_0000) && (mem_addr < 32'h000a_0000)) ? (mem_addr - 32'h0004_0000) :
                                                                   mem_addr;
  wire [31:0] mem_word_index = mem_addr_mapped[31:2];

  minirv dut (
    .clk(clk),
    .rstn(rstn),
    .pc(pc),
    .reg_a0(reg_a0),
    .mem_clk(mem_clk),
    .mem_addr(mem_addr),
    .mem_dataout(mem_dataout),
    .mem_datain(mem_datain),
    .mem_we(mem_we)
  );

  assign mem_dataout = mem_dataout_r;

  // 100 MHz clock.
  always #5 clk = ~clk;

  // Read path for RAM and framebuffer MMIO.
  always @(*) begin
    if (is_fb_addr) begin
      // F6 only requires `sw` to framebuffer, so readback can return zero.
      mem_dataout_r = 32'b0;
    end else if (mem_word_index < MEM_WORDS) begin
      mem_dataout_r = mem[mem_word_index];
    end else begin
      mem_dataout_r = 32'b0;
    end
  end

  // Write path for RAM and framebuffer MMIO.
  // `sb` merge is already performed in DUT; testbench writes full 32-bit words.
  always @(posedge mem_clk) begin
    if (mem_we) begin
      if (is_fb_addr) begin
        if (fb_dump_en && (fb_index < FB_WORDS)) begin
          // Record write events: "<pixel_index> <pixel_value>".
          $fdisplay(fb_event_fd, "%08x %08x", fb_index, mem_datain);
        end
      end else if (mem_word_index < MEM_WORDS) begin
        mem[mem_word_index] <= mem_datain;
      end
    end
  end

  initial begin
    clk = 1'b0;
    rstn = 1'b0;
    cycle_cnt = 0;
    trace_en = 0;
    fb_dump_en = 0;
    fb_event_fd = 0;

    if (!$value$plusargs("HEX=%s", hex_file)) begin
      $display("ERROR: missing +HEX=<hex_file>");
      $finish(1);
    end
    if (!$value$plusargs("MAX_CYCLES=%d", max_cycles)) begin
      max_cycles = 6000;
    end
    if (!$value$plusargs("TRACE=%d", trace_en)) begin
      trace_en = 0;
    end

    if ($value$plusargs("FBDUMP=%s", fb_dump_file)) begin
      fb_event_fd = $fopen(fb_dump_file, "w");
      if (fb_event_fd != 0) begin
        fb_dump_en = 1;
      end else begin
        $display("WARN: failed to open FBDUMP path");
      end
    end

    for (i = 0; i < MEM_WORDS; i = i + 1) begin
      mem[i] = 32'b0;
    end
    $readmemh(hex_file, mem);

    repeat (4) @(posedge clk);
    rstn = 1'b1;
  end

  always @(posedge clk) begin
    if (!rstn) begin
      cycle_cnt <= 0;
    end else begin
      cycle_cnt <= cycle_cnt + 1;

      if (trace_en != 0) begin
        $display("TRACE cycle=%0d pc=0x%08x a0=0x%08x", cycle_cnt + 1, pc, reg_a0);
      end

      if ((cycle_cnt + 1) >= max_cycles) begin
        if (fb_dump_en && (fb_event_fd != 0)) begin
          $fclose(fb_event_fd);
        end
        $display("FINAL pc=0x%08x a0=0x%08x cycles=%0d", pc, reg_a0, cycle_cnt + 1);
        $finish(0);
      end
    end
  end
endmodule
