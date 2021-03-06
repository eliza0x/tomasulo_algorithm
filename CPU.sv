`include "./src/Utility.sv"
`include "./src/ALU.sv"

module CPU(
    input wire CLOCK_50,
    input wire RSTN_N
);
    `include "./src/Parameter.sv"
    
    bit  clk;
    inst instCache[256];
    RegF regs[32];
    byte commit_index;
    byte write_index;
    inst pc;
    bit  is_halt_N;
    inst memory[1024];
    logic result_branch[8];
    inst result[16];
    bit  result_available[$size(result)];
    ReservationStation rstation[$size(result)];
    ReorderBuffer rbuffer[32];
    int  clk_cnt = 0;

    initial initialize();

    assign clk = CLOCK_50 & is_halt_N;

    // [設計] 
    // ROBから確定したものをコミット
    always @(posedge clk or negedge RSTN_N) begin
        clk_cnt = clk_cnt + 1;
        if (!RSTN_N) begin
            initialize();
        end else begin
            // Reorder Buffer: commit
            for (int i=0; i<32;i++) begin
                `define rc rbuffer[commit_index]
                if (`rc.available == 0 && `rc.alu == 0) begin
                    if (`rc.is_branch) begin
                        if (`rc.is_failure) begin
                            // [設計]
                            // 分岐予測に失敗したら投機的に実行した部分を捨てる
                            pc = `rc.value;
                            for (int i=0; i<$size(rbuffer); i++) rbuffer[i].available = 1;
                            for (int i=0; i<$size(rbuffer); i++) regs[i].in_rbuffer   = 1'b0;
                            commit_index = write_index;
                        end else begin
                            // [設計]
                            // 予測に成功すれば放置
                            commit_index = commit_index + 1;
                        end
                    end else if (`rc.is_resister) begin
                        // [設計]
                        // リオーダバッファからレジスタへの書き込み
                        $display("regs[%0d]  <- %0d",`rc.reg_num, `rc.value); 
                        regs[`rc.reg_num].data = `rc.value;

                        // レジスタの指すrbufferの番号が今のcommit_indexであれば書き込む
                        // そうでなければ後続の命令が書き込むのでスルー
                        // (Resister Renaming)
                        if ( regs[`rc.reg_num].in_rbuffer == 1'b1 
                          && regs[`rc.reg_num].rbuffer == commit_index) begin
                            regs[`rc.reg_num].in_rbuffer = 0;
                        end
                        `rc.available = 1;
                        commit_index = commit_index + 1;
                    end else if (`rc.is_store) begin
                        // [設計]
                        // メモリ操作キューに追加(未実装)
                        memory[`rc.address] = `rc.value;
                        `rc.available = 1;
                        commit_index = commit_index + 1;
                    end else if (`rc.is_halt) begin
                        is_halt_N = 0;
                        commit_index = commit_index + 1;
                    end
                end else begin
                    break;
                end
                `undef rc
            end
        end
    end

    // [設計] 
    // Bload Castを受信してリザベーションステーションとROBに書き込む
    always @(posedge clk) begin
        for (int l=1; l<$size(result); l++) begin
            if (result_available[l]) begin
                // Bload Cast: reorder buffer
                for (int i=0; i<$size(rbuffer); i++) begin
                    if (rbuffer[i].alu == l) begin
                        $display("reseive[%0d]: %0d", i ,result[l]); 
                        rbuffer[i].value <= result[l];
                        rbuffer[i].alu   <= 8'h00;
                        if (rbuffer[i].is_branch)
                            rbuffer[i].is_failure <= result_branch[l-8];
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
    end

    always @(posedge clk) begin
        automatic inst instruction;
        automatic byte rstation_num;
        // [設計]
        // Decode
        for (int l=1; l<$size(rstation); l++) begin
            instruction = instCache[pc];
            if (rbuffer[write_index].available) begin
                if (instruction[op_begin:op_end] == op_resister_resister) begin
                    if (instruction[funct3_begin:funct3_end] == funct3_add_sub) begin
                        if (instruction[funct7_begin:funct7_end] == funct7_add) begin
                            rstation_num = search_available_rstation(1, 4);
                            if (rstation_num != 0) begin
                                send_reservation_station_arith(instruction, rstation_num);
                                write_index   = write_index + 1;
                                pc = pc + 1;
                            end
                        end else if (instruction[funct7_begin:funct7_end] == funct7_sub) begin
                            rstation_num = search_available_rstation(5, 7);
                            if (rstation_num != 0) begin
                                send_reservation_station_arith(instruction, rstation_num);
                                write_index   = write_index + 1;
                                pc = pc + 1;
                            end
                        end
                    end
                end else if (instruction[op_begin:op_end] == op_conditional_branch) begin
                    if (instruction[funct3_begin:funct3_end] == funct3_beq) begin
                        rstation_num = search_available_rstation(8, 10);
                        if (rstation_num != 0) begin
                            send_reservation_station_conditional_branch(instruction, pc, rstation_num);
                            write_index = write_index + 1;
                            pc = pc + 1;
                        end
                    end
                end else if (instruction[op_begin:op_end] == op_nop) begin
                    pc = pc + 1;
                end else if (instruction[op_begin:op_end] == op_halt) begin
                    rstation_num = search_available_rstation(15, 15);
                    if (rstation_num != 0) begin
                        send_reservation_station_halt(rstation_num);
                        pc = pc + 1;
                        write_index   = write_index + 1;
                    end
                end
            end
        end
    end

    function void initialize(); // {{{
        clk_cnt <= 0;
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
        commit_index <= 0;
        write_index  <= 0;
        pc <= 0;
        is_halt_N <= 1;
    endfunction /// }}}

    function byte search_available_rstation(byte s, byte l); // {{{
        for (int i=s; i<=l; i++)
            if (!rstation[i].busy)
                return i;
        return 0;
    endfunction // }}}

    function void send_reservation_station_arith(inst instruction, byte i); // {{{
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
        rbuffer[write_index].alu         = i;
        rbuffer[write_index].reg_num     = instruction[rd_begin:rd_end];
        rbuffer[write_index].available   = 1'b0;
        rbuffer[write_index].is_store    = 1'b0;
        rbuffer[write_index].is_branch   = 1'b0;
        rbuffer[write_index].is_halt     = 1'b0;
        rbuffer[write_index].is_resister = 1'b1;
        regs[instruction[rd_begin:rd_end]].rbuffer    = write_index;
        regs[instruction[rd_begin:rd_end]].in_rbuffer = 1'b1;
    endfunction // }}}

    function void send_reservation_station_conditional_branch(inst instruction, inst pc, byte i); // {{{
        automatic inst offset;        
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

        `define h instruction[0]
        offset = {`h,`h,`h,`h,`h,`h,`h,`h,`h,`h,`h,`h,`h,`h,`h,`h,`h,`h,`h,`h,
            `h,instruction[24],instruction[6:1],instruction[23:20]};
        `undef h
        rstation[i].busy                 = 1'b1;
        rstation[i].address              = pc;
        rstation[i].address_offset       = offset;
        rbuffer[write_index].alu         = i;
        rbuffer[write_index].available   = 1'b0;
        rbuffer[write_index].is_store    = 1'b0;
        rbuffer[write_index].is_resister = 1'b0;
        rbuffer[write_index].is_branch   = 1'b1;
        rbuffer[write_index].is_halt     = 1'b0;
    endfunction // }}}

    function void send_reservation_station_halt(byte i); // {{{
        rstation[i].busy                  = 1'b1;
        rbuffer[write_index].alu          = 0;
        rbuffer[write_index].reg_num      = 0;
        rbuffer[write_index].available    = 0;
        rbuffer[write_index].is_resister  = 1'b0;
        rbuffer[write_index].is_store     = 1'b0;
        rbuffer[write_index].is_branch    = 1'b0;
        rbuffer[write_index].is_halt      = 1'b1;
    endfunction // }}}

    function void send_reservation_station_nop(byte i); // {{{
        rstation[i].busy                  = 1'b1;
        rbuffer[write_index].alu          = 0;
        rbuffer[write_index].reg_num      = 0;
        rbuffer[write_index].available    = 0;
        rbuffer[write_index].is_resister  = 1'b0;
        rbuffer[write_index].is_store     = 1'b0;
        rbuffer[write_index].is_branch    = 1'b0;
        rbuffer[write_index].is_halt      = 1'b0;
    endfunction // }}}

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
        for (i=8; i<=10; i++) begin : beq_module_block
            Beq beq_module (
                .rstation(rstation[i]),
                .result(result[i]),
                .result_branch(result_branch[i-8]),
                .result_available(result_available[i]),
                .*
            );
        end
    endgenerate 
endmodule

module Beq(
    input wire                clk,
    input wire                RSTN_N,
    input ReservationStation  rstation,
    output logic [31:0]       result,
    output logic              result_branch,
    output logic              result_available
);

    always @(posedge clk or negedge RSTN_N) begin
        if (!RSTN_N) begin
            result_available <= 0;
            result           <= 0;
        end else begin
            if (rstation.alu1==8'd0 && rstation.alu2==8'd0 && rstation.busy) begin
                result_available <= 1;
                result_branch <= rstation.value1 == rstation.value2;
                result <= rstation.address + rstation.address_offset;
                $display("result: %0d", rstation.address + rstation.address_offset);
                $display("result_branch: %0d", rstation.value1 == rstation.value2);
            end else begin
                result_available <= 0;
                result           <= 0;
            end
        end
    end
endmodule
