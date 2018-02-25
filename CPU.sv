`include "./src/Utility.sv"

module CPU(
    input wire CLOCK_50,
    input wire RSTN_N
);
    `include "./src/Parameter.sv"
    
    /* 変数定義 {{{ */
    inst [1023:0] memory;
    inst instCache[256];
    RegF regs[32];
    inst result[8];
    inst result_branch[8];
    bit  result_available[$size(result)];
    ReservationStation rstation[$size(result)];
    ReorderBuffer rbuffer[32];
    byte commit_pointer;
    byte write_pointer;
    inst pc;
    /* }}} */

    /* 初期化 {{{ */
    initial begin
        for (int i=0; i<32; i++) begin
            regs[i].in_rbuffer <= 1'd0;
            regs[i].data       <= 32'b0;
        end
        for (int i=0; i<$size(rstation); i++) begin
            rstation[i].busy   <= 1'b0;
            rstation[i].alu1   <= 8'd0;
            rstation[i].alu2   <= 8'd0;
            rstation[i].value1 <= 32'd0;
            rstation[i].value2 <= 32'd0;
        end
        for (int i=0; i<$size(rbuffer); i++) begin
            rbuffer[i].available  = 1;
            rbuffer[i].is_failure = 0;
        end
        commit_pointer <= 0;
        write_pointer  <= 0;
        pc <= 0;
    end
    /* }}} */

    always @(posedge CLOCK_50 or negedge RSTN_N) begin
        if (!RSTN_N) begin
            /* RESET {{{ */
            for (int i=0; i<32; i++) begin
                regs[i].in_rbuffer <= 0;
                regs[i].data       <= 32'b0;
            end
            for (int i=0; i<$size(rstation); i++) begin
                rstation[i].busy   <= 1'b0;
                rstation[i].alu1   <= 2'b00;
                rstation[i].alu2   <= 2'b00;
                rstation[i].value1 <= 32'd0;
                rstation[i].value2 <= 32'd0;
            end
            for (int i=0; i<$size(rbuffer); i++) begin
                rbuffer[i].available = 1;
            end
            pc <= 0;
            commit_pointer <= 0;
            write_pointer  <= 0;
            /* }}} */
        end else begin
            automatic inst instruction;
            automatic byte consumed_inst = 0;
            automatic bit is_branch_loaded = 0;
            automatic bit is_rbuffer_clear = 0;

            // Reorder Buffer: commit {{{
            for (int i=0; i<32;i++) begin
                if ( rbuffer[commit_pointer].available  == 0
                  && rbuffer[commit_pointer].alu        == 0 ) begin
                    $display("commitable");
                    // Reorder Buffer -> branch failure
                    if ( !is_rbuffer_clear 
                      && rbuffer[commit_pointer].is_branch 
                      && rbuffer[commit_pointer].is_failure) begin
                        // is_rbuffer_clear: rbufferのフラッシュ
                        for (int i=0; i<$size(rbuffer); i++) begin
                            rbuffer[i].available = 1;
                        end
                        // is_rbuffer_clear: regfileのコミット予約をフラッシュ
                        for (int i=0; i<$size(rbuffer); i++) begin
                            regs[i].in_rbuffer = 1'b0;
                        end
                        
                        commit_pointer = write_pointer;
                    end else if (!is_rbuffer_clear && !rbuffer[commit_pointer].is_store) begin
                    // Reorder Buffer -> register file
                        $display("regs[%2d]  <- %0d",rbuffer[commit_pointer].reg_num, rbuffer[commit_pointer].value); 
                        regs[rbuffer[commit_pointer].reg_num].data = rbuffer[commit_pointer].value;

                        if ( regs[rbuffer[commit_pointer].reg_num].in_rbuffer == 1'b1
                          && regs[rbuffer[commit_pointer].reg_num].rbuffer    == commit_pointer) begin
                            regs[rbuffer[commit_pointer].reg_num].in_rbuffer = 0;
                        end
                        
                        rbuffer[commit_pointer].available = 1;
                        commit_pointer = commit_pointer + 1;
                    end else if (!is_rbuffer_clear && rbuffer[commit_pointer].is_store) begin
                    // Reorder Buffer -> memory
                        memory[rbuffer[commit_pointer].address] = rbuffer[commit_pointer].value;
                        rbuffer[commit_pointer].available = 1;
                        commit_pointer = commit_pointer + 1;
                    end
                end else begin
                    break;
                end
            end
            // }}}

            for (int l=1; l<$size(result); l++) begin
                if (result_available[l]) begin
                    // Bload Cast: reorder buffer
                    for (int i=0; i<$size(rbuffer); i++) begin
                        if (rbuffer[i].alu == l) begin
                            $display("buffer reseive[%2d]: %0d", i ,result[l]); 
                            rbuffer[i].value = result[l];
                            rbuffer[i].alu   = 8'h00;
                            if (rbuffer[i].is_branch) begin
                                rbuffer[i].is_failure = result_branch[l];
                            end
                        end
                    end

                    // Bload Cast: reservation station
                    for (int i=0; i<$size(rstation); i++) begin
                        if (rstation[i].alu1 == l) begin
                            rstation[i].value1 <= result[l];
                            rstation[i].alu1   <= 8'd0;
                            rstation[l].busy   <= 0;
                        end

                        if (rstation[i].alu2 == l) begin
                            rstation[i].value2 <= result[l];
                            rstation[i].alu2   <= 8'd0;
                            rstation[l].busy   <= 0;
                        end
                    end
                end
            end

            for (int l=1; l<$size(rstation); l++) begin
                if (!is_branch_loaded) begin
                    instruction = instCache[pc+consumed_inst];

                    if (rbuffer[write_pointer].available) begin
                        // Resister-Resister Operation
                        if (instruction[op_begin:op_end] == 7'b1100110) begin
                            // ADD, SUB
                            if (instruction[funct3_begin:funct3_end] == 3'b000) begin
                                // ADD
                                if (instruction[funct7_begin:funct7_end] == 7'b0000000) begin
                                    for (int i=1; i<=4; i++) begin
                                        if (!rstation[i].busy) begin
                                            $display("i: %d", i);
                                            send_reservation_station(instruction, write_pointer, i);
                                            write_pointer = write_pointer + 1;
                                            consumed_inst = consumed_inst + 1;
                                            break;
                                        end
                                    end
                                end else if (instruction[funct7_begin:funct7_end] == 7'b0000010) begin
                                    for (int i=5; i<=7; i++) begin
                                        if (!rstation[i].busy) begin
                                            send_reservation_station(instruction, write_pointer, i);
                                            write_pointer = write_pointer + 1;
                                            consumed_inst = consumed_inst + 1;
                                            break;
                                        end
                                    end
                                end
                            end
                        end else if (instruction[op_begin:op_end] == 7'b0000000) begin
                            consumed_inst = consumed_inst + 1;
                        end
                    end
                end
            end
            pc = pc + consumed_inst;
        end
    end

    function void send_reservation_station(inst instruction, byte write_pointer, byte i);
        // rs1 is available
        if (regs[instruction[rs1_begin:rs1_end]].in_rbuffer == 1'b0) begin
            rstation[i].value1 = regs[instruction[rs1_begin:rs1_end]].data;
            rstation[i].alu1   = 8'd0;
        end else begin
            if (rbuffer[regs[instruction[rs1_begin:rs1_end]].rbuffer].alu == 0) begin
                rstation[i].value1 = rbuffer[regs[instruction[rs1_begin:rs1_end]].rbuffer].value;
                rstation[i].alu1 = 8'd0;
            end else begin
                rstation[i].value1 = 32'd0;
                rstation[i].alu1   = rbuffer[regs[instruction[rs1_begin:rs1_end]].rbuffer].alu;
            end
        end
                                                                 
        // rs2 is available
        if (regs[instruction[rs2_begin:rs2_end]].in_rbuffer == 1'b0) begin
            rstation[i].value2 = regs[instruction[rs2_begin:rs2_end]].data;
            rstation[i].alu2   = 8'd0;
        end else begin
            if (rbuffer[regs[instruction[rs2_begin:rs2_end]].rbuffer].alu == 0) begin
                rstation[i].value2 = rbuffer[regs[instruction[rs2_begin:rs2_end]].rbuffer].value;
                rstation[i].alu2 = 8'd0;
            end else begin
                rstation[i].value2 = 32'd0;
                rstation[i].alu2   = rbuffer[regs[instruction[rs2_begin:rs2_end]].rbuffer].alu;
            end
        end

        rstation[i].busy                 = 1'b1;
        rbuffer[write_pointer].alu       = i;
        rbuffer[write_pointer].reg_num   = instruction[rd_begin:rd_end];
        rbuffer[write_pointer].available = 0;
        rbuffer[write_pointer].is_store  = 0;
        regs[instruction[rd_begin:rd_end]].rbuffer    = write_pointer;
        regs[instruction[rd_begin:rd_end]].in_rbuffer = 1'b1;
    endfunction

    genvar i;
    generate
        for (i=1; i<=4; i++) begin : add_module_block
            Add add_module (
                .rstation(rstation[i]),
                .result(result[i]),
                .result_available(result_available[i]),
                .*
            );
        end
        for (i=5; i<=7; i++) begin : sub_module_block
            Sub sub_module (
                .rstation(rstation[i]),
                .result(result[i]),
                .result_available(result_available[i]),
                .*
            );
        end
    endgenerate 
endmodule

// 実験の為に1クロック遅延を発生させている
module Add(
    input wire                CLOCK_50,
    input wire                RSTN_N,
    input ReservationStation  rstation,
    output logic [31:0]       result,
    output logic              result_available
);

    bit b_result_available = 0;
    logic [31:0] b_result = 0;

    bit calculated = 0;

    always @(posedge CLOCK_50 or negedge RSTN_N) begin
        if (!RSTN_N) begin
            result_available <= 0;
            result           <= 0;
        end else begin
            if (!calculated && rstation.alu1==8'd0 && rstation.alu2==8'd0 && rstation.busy) begin
                b_result_available <= 1;
                b_result   <= rstation.value1 + rstation.value2;

                result_available <= b_result_available;
                result           <= b_result;
                calculated <= 1;
            end else if (calculated && rstation.alu1==8'd0 && rstation.alu2==8'd0 && rstation.busy) begin
                b_result_available <= 0;
                b_result           <= 0;

                result_available <= b_result_available;
                result           <= b_result;
                calculated       <= 0;
            end else begin
                b_result_available <= 0;
                b_result           <= 0;
            end
        end
    end
endmodule

module Sub(
    input wire                CLOCK_50,
    input wire                RSTN_N,
    input ReservationStation  rstation,
    output logic [31:0]       result,
    output logic              result_available
);

    always @(posedge CLOCK_50 or negedge RSTN_N) begin
        if (!RSTN_N) begin
            result_available <= 0;
            result           <= 0;
        end else begin
            if (rstation.alu1==8'd0 && rstation.alu2==8'd0 && rstation.busy) begin
                result_available <= 1;
                result <= rstation.value1 - rstation.value2;
            end else begin
                result_available <= 0;
                result           <= 0;
            end
        end
    end
endmodule

