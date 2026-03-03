`timescale 1ns / 1ps

// -----------------------------------------------------------------------------
// miniRV (teaching-oriented RV32I subset core)
// -----------------------------------------------------------------------------
// This core is intentionally minimal and only supports the instruction subset
// required by the current YSYX miniRV task:
//   add, addi, lui, lw, lbu, sw, sb, jalr
//
// Architectural choices:
// 1) Two-cycle FSM per instruction:
//      cycle A: FETCH  -> read instruction word at PC
//      cycle B: EXEC   -> decode/execute/writeback, then update PC
//    So CPI is approximately 2 for all supported instructions.
//
// 2) Single unified memory port:
//    Instruction fetch and data load/store share one memory interface.
//    - FETCH state uses mem_addr = pc
//    - EXEC state uses mem_addr = data address for load/store instructions
//
// 3) Register file:
//    32 x 32-bit regs, with x0 hard-wired to zero.
//
// 4) Byte semantics on a word memory interface:
//    - lbu selects one byte from mem_dataout and zero-extends
//    - sb performs read-modify-write via mask/merge logic
//
// Interface contract (external TB/memory model should match):
//   mem_addr    : byte address
//   mem_dataout : 32-bit word read from aligned address
//   mem_datain  : 32-bit data for write
//   mem_we      : write enable (word write, sb pre-merged by core)
module minirv(
  input         clk,
  input         rstn,
  output [31:0] pc,
  output [31:0] reg_a0,
  output        mem_clk,
  output [31:0] mem_addr,
  input  [31:0] mem_dataout,
  output [31:0] mem_datain,
  output        mem_we
);
  // Two-state control FSM.
  localparam STATE_FETCH = 1'b0;
  localparam STATE_EXEC  = 1'b1;

  // Main architectural states.
  reg [31:0] pc_r;            // program counter
  reg [31:0] instr_r;         // latched instruction (from FETCH)
  reg        state_r;         // current FSM state
  reg [31:0] regs [0:31];     // integer register file

  // Combinational-like temporaries evaluated in EXEC state.
  reg [31:0] next_pc;         // computed next PC
  reg        wb_en;           // writeback enable
  reg [4:0]  wb_rd;           // writeback destination register index
  reg [31:0] wb_data;         // writeback value

  integer i;

  // Extract standard RV32 instruction fields from latched instruction.
  wire [6:0] opcode = instr_r[6:0];
  wire [4:0] rd     = instr_r[11:7];
  wire [2:0] funct3 = instr_r[14:12];
  wire [4:0] rs1    = instr_r[19:15];
  wire [4:0] rs2    = instr_r[24:20];
  wire [6:0] funct7 = instr_r[31:25];

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
  wire [31:0] imm_i = {{20{instr_r[31]}}, instr_r[31:20]};
  wire [31:0] imm_s = {{20{instr_r[31]}}, instr_r[31:25], instr_r[11:7]};
  wire [31:0] imm_u = {instr_r[31:12], 12'b0};

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

  // Debug/observe outputs required by the assignment harness.
  assign pc     = pc_r;
  assign reg_a0 = regs[10];  // x10 = a0

  // Tie memory clock to core clock in this simple synchronous model.
  assign mem_clk = clk;
  // Address selection:
  // - FETCH: instruction fetch at current pc
  // - EXEC + memory op: data access address
  // - EXEC + non-memory op: address value is don't-care for correctness
  assign mem_addr = (state_r == STATE_FETCH) ? pc_r :
                    ((is_lw || is_lbu || is_sw || is_sb) ? ls_addr_aligned : pc_r);
  // For sb, send merged word; for other stores, send rs2 full word.
  assign mem_datain = is_sb ? sb_data : rs2_val;
  // Write only in EXEC when instruction is sw/sb.
  assign mem_we = (state_r == STATE_EXEC) && (is_sw || is_sb);

  always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      // Reset architectural state.
      pc_r    <= 32'b0;
      instr_r <= 32'b0;
      state_r <= STATE_FETCH;
      for (i = 0; i < 32; i = i + 1) begin
        regs[i] <= 32'b0;
      end
    end else begin
      if (state_r == STATE_FETCH) begin
        // FETCH stage:
        // read instruction from mem_dataout and latch it for next EXEC stage.
        instr_r <= mem_dataout;
        state_r <= STATE_EXEC;
      end else begin
        // EXEC stage:
        // decode + execute + optional writeback + pc update.
        next_pc = pc_r + 32'd4;
        wb_en   = 1'b0;
        wb_rd   = rd;
        wb_data = 32'b0;

        if (is_add) begin
          // add rd, rs1, rs2
          wb_en   = 1'b1;
          wb_data = rs1_val + rs2_val;
        end else if (is_addi) begin
          // addi rd, rs1, imm
          wb_en   = 1'b1;
          wb_data = rs1_val + imm_i;
        end else if (is_lui) begin
          // lui rd, imm20
          wb_en   = 1'b1;
          wb_data = imm_u;
        end else if (is_lw) begin
          // lw rd, imm(rs1): mem_dataout is full 32-bit aligned word.
          wb_en   = 1'b1;
          wb_data = mem_dataout;
        end else if (is_lbu) begin
          // lbu rd, imm(rs1): select byte and zero-extend.
          wb_en   = 1'b1;
          wb_data = lbu_data;
        end else if (is_jalr) begin
          // jalr rd, rs1, imm:
          // - rd gets return address (pc + 4)
          // - next_pc uses target address with bit0 cleared (RV32I rule)
          wb_en   = 1'b1;
          wb_data = pc_r + 32'd4;
          next_pc = (rs1_val + imm_i) & 32'hffff_fffe;
        end

        // Register writeback (except x0).
        if (wb_en && (wb_rd != 5'd0)) begin
          regs[wb_rd] <= wb_data;
        end
        // Keep x0 hardwired to zero every cycle.
        regs[0] <= 32'b0;

        // Commit next PC and return to FETCH state.
        pc_r    <= next_pc;
        state_r <= STATE_FETCH;
      end
    end
  end
endmodule
