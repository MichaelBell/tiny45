/* Tiny45: A RISC-V core designed to use minimal area.
  
   This core module takes decoded instructions and produces output data
 */

module tiny45_core #(parameter NUM_REGS=16, parameter REG_ADDR_BITS=4) (
    input clk,
    input rstn,

    input [3:0] imm,

    input is_load,
    input is_alu_imm,
    input is_auipc,
    input is_store,
    input is_alu_reg,
    input is_lui,
    input is_branch,
    input is_jalr,
    input is_jal,
/*verilator lint_off UNUSEDSIGNAL*/
    input is_system,
/*verilator lint_on UNUSEDSIGNAL*/
    input is_stall,

    input [3:0] alu_op,  // See tiny45_alu for format
    input [2:0] mem_op,

    input [REG_ADDR_BITS-1:0] rs1,
    input [REG_ADDR_BITS-1:0] rs2,
    input [REG_ADDR_BITS-1:0] rd,

    input [2:0] counter,    // Sub cycle counter, must increment on every clock
    input [3:0] pc,
    input [3:0] next_pc,
    input [3:0] data_in,
    input load_data_ready,

    output reg [3:0] data_out,  // Data for the active store instruction
    output [27:0] addr_out,
    output address_ready,   // The addr_out holds the address for the active load/store instruction
    output reg instr_complete,  // The current instruction will complete this clock, so the instruction may be updated.
                            // If no new instruction is available all a NOOP should be issued, which will complete in 1 cycle.
    output branch           // addr_out holds the address to branch to
);

    ///////// Register file /////////

    wire [3:0] data_rs1;
    wire [3:0] data_rs2;
    reg [3:0] data_rd;
    reg wr_en;

    reg [31:0] tmp_data;

    tiny45_registers #(.REG_ADDR_BITS(REG_ADDR_BITS), .NUM_REGS(NUM_REGS)) 
        i_registers(clk, rstn, wr_en, counter, rs1, rs2, rd, data_rs1, data_rs2, data_rd);


    ///////// ALU /////////

    wire is_slt = alu_op[3:1] == 3'b001;

    reg [2:0] alu_cycles;
    always @(*) begin
        if (is_slt || is_shift) alu_cycles = 1;
        else alu_cycles = 0;
    end

    reg cy;
    reg cmp;
    wire [3:0] alu_op_in = (is_branch && cycle == 1) ? 0 : alu_op;
    wire [3:0] alu_a_in = (is_auipc || is_jal || (is_branch && cycle == 1)) ? pc : data_rs1;
    wire [3:0] alu_b_in = (is_alu_reg || (is_branch && cycle == 0)) ? data_rs2 : imm;
    wire [3:0] alu_out;
    wire cy_in = (counter == 0) ? (alu_op_in[1] || alu_op_in[3]) : cy;
    wire cmp_in = (counter == 0) ? 1'b1 : cmp;
    wire cy_out, cmp_out;

    tiny45_alu i_alu(alu_op_in, alu_a_in, alu_b_in, cy_in, cmp_in, alu_out, cy_out, cmp_out);

    always @(posedge clk) begin
        cy <= cy_out;
        cmp <= cmp_out;
    end

    ///////// Shifter /////////

    wire is_shift = alu_op[1:0] == 2'b01;

    reg [4:0] shift_amt;
    always @(posedge clk) begin
        if (cycle == 0) begin
            if (counter == 0) shift_amt[3:0] <= is_alu_imm ? imm : data_rs2;
            else if (counter == 1) shift_amt[4] <= is_alu_imm ? imm[0] : data_rs2[0];
        end
    end

    wire [3:0] shift_out;
    tiny45_shifter i_shift(alu_op[3:2], counter, tmp_data, shift_amt, shift_out);


    ///////// Writeback /////////

    reg load_top_bit_next;
    reg load_top_bit;
    always @(*) begin
        load_top_bit_next = (counter == 0) ? 0 : load_top_bit;
        if (is_load && load_data_ready &&
            ((mem_op == 3'b001 && counter == 3) || 
             (mem_op == 3'b000 && counter == 1)))
        begin
            load_top_bit_next = data_in[3];
        end
    end

    always @(posedge clk)
        load_top_bit <= load_top_bit_next;

    always @(*) begin
        wr_en = 0;
        data_rd = 0;
        if (is_alu_imm || is_alu_reg || is_auipc) begin
            wr_en = 1;
            if (is_slt && cycle == 1 && counter == 0)
                data_rd = {3'b000, cmp};
            else if (is_shift && cycle == 1)
                data_rd = shift_out;
            else
                data_rd = alu_out;

        end else if (is_load && load_data_ready) begin
            wr_en = 1;
            if ((mem_op[1:0] == 2'b00 && counter > 1) ||
                (mem_op[1:0] == 2'b01 && counter > 3))
                data_rd = {4{load_top_bit}};
            else
                data_rd = data_in;

        end else if (is_lui) begin
            wr_en = 1;
            data_rd = imm;
        end else if (is_jal || is_jalr) begin
            wr_en = 1;
            data_rd = next_pc;
        end
    end


    ///////// Branching /////////

    assign branch = last_count && ((cycle == 0 && (is_jal || is_jalr)) || (cycle == 1 && is_branch));
    wire take_branch = last_count && (cmp_out ^ mem_op[0]);


    ///////// Cycle management /////////

    wire last_count = (counter == 7);

    reg [2:0] cycle;
    always @(posedge clk) begin
        if (!rstn) cycle <= 0;
        else if (last_count) begin
            if (instr_complete) cycle <= 0;
            else if (cycle != 3'b111) cycle <= cycle + 1;
        end
    end

    always @(*) begin
        instr_complete = 0;
        if (last_count) begin
            if (is_alu_imm || is_alu_reg)
                instr_complete = cycle == alu_cycles;
            else if (is_auipc || is_lui || is_store || is_jal || is_jalr || is_stall)
                instr_complete = 1;
            else if (load_done && is_load)
                instr_complete = 1;
            else if (is_branch) begin
                if (cycle == 0 && !take_branch) instr_complete = 1;
                else if (cycle == 1) instr_complete = 1;
            end
        end
    end

    reg load_done;
    always @(posedge clk) begin
        if (counter == 0)
            load_done <= load_data_ready;
    end

    assign address_ready = last_count && (cycle == 0) && (is_load || is_store);


    ///////// Working temporary data /////////

    reg [3:0] tmp_data_in;
    reg tmp_data_shift;
    
    always @(*) begin
        tmp_data_shift = 1;
        if (is_shift)
            tmp_data_in = data_rs1;
        else if (cycle == 0 || is_branch)
            tmp_data_in = alu_out;
        else
            tmp_data_in = data_rs2;
        
        if (cycle == 1 && is_shift)
            tmp_data_shift = 0;
    end

    always @(posedge clk) begin
        if (tmp_data_shift)
            tmp_data <= {tmp_data_in, tmp_data[31:4]};
    end

    assign addr_out = tmp_data[31:4];

    always @(*) begin
        data_out = data_rs2;
        if ((mem_op[1:0] == 2'b00 && counter > 1) ||
            (mem_op[1:0] == 2'b01 && counter > 3))
            data_out = 0;
    end

endmodule
