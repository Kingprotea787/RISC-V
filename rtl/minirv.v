`timescale 1ns / 1ps

// -----------------------------------------------------------------------------
// miniRV (teaching-oriented RV32I subset core)
// -----------------------------------------------------------------------------
// This core is intentionally minimal and only supports the instruction subset
// required by the current YSYX miniRV task:
//   add, addi, lui, lw, lbu, sw, sb, jalr
//
// Architectural choices:
// 1) Single-cycle execution:
//      Each instruction completes in one clock cycle (fetch, decode, execute, writeback).
//    So CPI is 1 for all supported instructions.
//
// 2) Separate instruction and data memory ports:
//    - imem_addr: instruction fetch address (always = PC)
//    - imem_dataout: instruction word
//    - mem_addr: data memory address for load/store
//    - mem_dataout: data read from memory
//    - mem_datain: data to write to memory
//    - mem_we: write enable for data memory
//
// 3) Register file:
//    32 x 32-bit regs, with x0 hard-wired to zero.
//
// 4) Byte semantics on a word memory interface:
//    - lbu selects one byte from mem_dataout and zero-extends
//    - sb performs read-modify-write via mask/merge logic
//
// Interface contract (external TB/memory model should match):
//   imem_addr   : instruction memory byte address
//   imem_dataout: 32-bit instruction word
//   mem_addr    : data memory byte address
//   mem_dataout : 32-bit word read from aligned address
//   mem_datain  : 32-bit data for write
//   mem_we      : write enable (word write, sb pre-merged by core)
module minirv(
  input         clk,
  input         rstn,
  output [31:0] pc,
  output [31:0] reg_a0,
  output        mem_clk,
  output [31:0] imem_addr,
  input  [31:0] imem_dataout,
  output [31:0] mem_addr,
  input  [31:0] mem_dataout,
  output [31:0] mem_datain,
  output        mem_we
);
  // Main architectural states.
  reg [31:0] pc_r;            // program counter
  reg [31:0] regs [0:31];     // integer register file

  // Current instruction (combinational from instruction memory).
  wire [31:0] instr = imem_dataout;

  integer i;

  // Extract standard RV32 instruction fields from current instruction.
  wire [6:0] opcode = instr[6:0];
  wire [4:0] rd     = instr[11:7];
  wire [2:0] funct3 = instr[14:12];
  wire [4:0] rs1    = instr[19:15];
  wire [4:0] rs2    = instr[24:20];
  wire [6:0] funct7 = instr[31:25];

  // One-hot-like decode flags for supported instructions.
  wire is_add  = (opcode == 7'b0110011) && (funct3 == 3'b000) && (funct7 == 7'b0000000);
  wire is_addi = (opcode == 7'b0010011) && (funct3 == 3'b000);
  wire is_lui  = (opcode == 7'b0110111);
  wire is_lw   = (opcode == 7'b0000011) && (funct3 == 3'b010);
  wire is_lbu  = (opcode == 7'b0000011) && (funct3 == 3'b100);
  wire is_sw   = (opcode == 7'b0100011) && (funct3 == 3'b010);
  wire is_sb   = (opcode == 7'b0100011) && (funct3 == 3'b000);
  wire is_jalr = (opcode == 7'b1100111) && (funct3 == 3'b000);

  // Immediate decoding (sign extension per RV32I spec).
  wire [31:0] imm_i = {{20{instr[31]}}, instr[31:20]};
  wire [31:0] imm_s = {{20{instr[31]}}, instr[31:25], instr[11:7]};
  wire [31:0] imm_u = {instr[31:12], 12'b0};

  // Register source reads are combinational.
  wire [31:0] rs1_val = regs[rs1];
  wire [31:0] rs2_val = regs[rs2];

  // Effective byte address for load/store.
  // For store instructions, immediate is S-type; otherwise I-type.
  wire [31:0] ls_addr_raw     = rs1_val + ((is_sw || is_sb) ? imm_s : imm_i);
  // Memory model is word-oriented; align low 2 bits when driving mem_addr.
  wire [31:0] ls_addr_aligned = {ls_addr_raw[31:2], 2'b00};
  // Keep original low 2 bits for byte select inside that word.
  wire [1:0]  ls_byte_sel     = ls_addr_raw[1:0];

  // lbu: choose one byte from read word and zero-extend to 32 bits.
  wire [31:0] lbu_data = (ls_byte_sel == 2'd0) ? {24'b0, mem_dataout[7:0]}   :
                         (ls_byte_sel == 2'd1) ? {24'b0, mem_dataout[15:8]}  :
                         (ls_byte_sel == 2'd2) ? {24'b0, mem_dataout[23:16]} :
                                                  {24'b0, mem_dataout[31:24]};

  // sb: mask and merge one target byte into the original 32-bit word.
  wire [31:0] sb_mask = (ls_byte_sel == 2'd0) ? 32'h000000ff :
                        (ls_byte_sel == 2'd1) ? 32'h0000ff00 :
                        (ls_byte_sel == 2'd2) ? 32'h00ff0000 :
                                                 32'hff000000;

  wire [31:0] sb_shifted_byte = ({24'b0, rs2_val[7:0]} << (ls_byte_sel * 8));
  wire [31:0] sb_data         = (mem_dataout & (~sb_mask)) | (sb_shifted_byte & sb_mask);

  // Compute next PC and writeback signals (all combinational).
  wire [31:0] next_pc = is_jalr ? ((rs1_val + imm_i) & 32'hffff_fffe) : (pc_r + 32'd4);

  wire        wb_en = is_add || is_addi || is_lui || is_lw || is_lbu || is_jalr;
  wire [31:0] wb_data = is_add  ? (rs1_val + rs2_val) :
                        is_addi ? (rs1_val + imm_i) :
                        is_lui  ? imm_u :
                        is_lw   ? mem_dataout :
                        is_lbu  ? lbu_data :
                        is_jalr ? (pc_r + 32'd4) :
                        32'b0;

  // Debug/observe outputs required by the assignment harness.
  assign pc     = pc_r;
  assign reg_a0 = regs[10];  // x10 = a0

  // Tie memory clock to core clock in this simple synchronous model.
  assign mem_clk = clk;

  // Instruction memory always fetches from PC.
  assign imem_addr = pc_r;

  // Data memory address for load/store operations.
  assign mem_addr = ls_addr_aligned;

  // For sb, send merged word; for other stores, send rs2 full word.
  assign mem_datain = is_sb ? sb_data : rs2_val;

  // Write enable for store instructions.
  assign mem_we = is_sw || is_sb;

  always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      // Reset architectural state.
      pc_r <= 32'b0;
      for (i = 0; i < 32; i = i + 1) begin
        regs[i] <= 32'b0;
      end
    end else begin
      // Single-cycle execution: fetch, decode, execute, writeback all in one cycle.

      // Register writeback (except x0).
      if (wb_en && (rd != 5'd0)) begin
        regs[rd] <= wb_data;
      end
      // Keep x0 hardwired to zero every cycle.
      regs[0] <= 32'b0;

      // Update PC for next cycle.
      pc_r <= next_pc;
    end
  end
endmodule
