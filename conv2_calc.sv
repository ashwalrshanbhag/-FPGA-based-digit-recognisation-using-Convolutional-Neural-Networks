`timescale 1ns / 1ps

module conv2_calc
    #(
        parameter WEIGHT_1 = "conv2_weight_11.mem",
                  WEIGHT_2 = "conv2_weight_12.mem",
                  WEIGHT_3 = "conv2_weight_13.mem"
    )
    (
        input  wire                 clk,
        input  wire                 rst_n,
        input  wire                 valid_out_buf, // high if pixels are coming 
        
        // Bundled Multi-Channel Ports: 3 channels, each delivering 25 pixels simultaneously
        input  wire signed [11:0]   data_in [0:2][0:24],  // output of relu is 144*3  =432 pixels . data_in =5*5 matrix 
        
        output wire        [13:0]   conv_out_calc,// kept 14 , after 12bit * 8 bit mul and  then addition operation 75 times 
        output wire                 valid_out_calc
    );

    // Filter properties
    localparam KERNEL_SIZE = 25;

    // Weight Storages
    reg signed [7:0] weights [0:2][0:KERNEL_SIZE-1];

    // Load weights dynamically at startup
    initial begin
        $readmemh(WEIGHT_1, weights[0]);
        $readmemh(WEIGHT_2, weights[1]);
        $readmemh(WEIGHT_3, weights[2]);
    end

    // =========================================================================
    // PIPELINE STAGE 1: Parallel Multiplication & First Adder Level
    // =========================================================================
    // Your code groups pairs of multiplications together right at the start.
    // e.g., (pix0 * wt0) + (pix1 * wt1). There are 12 pairs and 1 leftover element.
    reg signed [19:0] stage1_sums [0:2][0:12];

    generate
        genvar ch, i;
        for (ch = 0; ch < 3; ch = ch + 1) begin : gen_channels
            for (i = 0; i < 12; i = i + 1) begin : gen_stage1_pairs
                always @(posedge clk) begin
                    if (~rst_n)
                        stage1_sums[ch][i] <= 20'sd0;
                    else
                        stage1_sums[ch][i] <= (data_in[ch][i*2]   * weights[ch][i*2]) +    // 3 channels 
                                              (data_in[ch][i*2+1] * weights[ch][i*2+1]);
                end
            end
            // Handle the 25th lone pixel element (Index 24)
            always @(posedge clk) begin
                if (~rst_n)
                    stage1_sums[ch][12] <= 20'sd0;
                else
                    stage1_sums[ch][12] <= data_in[ch][24] * weights[ch][24];
            end
        end
    endgenerate

    // =========================================================================
    // PIPELINE STAGES 2, 3, & 4: Pipelined Accumulation Trees
    // =========================================================================
    reg signed [19:0] stage2_sums [0:2][0:5];
    reg signed [19:0] stage3_sums [0:2][0:2];
    reg signed [19:0] stage4_final [0:2];

    always @(posedge clk) begin    
        if (~rst_n) begin
            stage2_sums  <= '{default: '{default: 0}};
            stage3_sums  <= '{default: '{default: 0}};
            stage4_final <= '{default: 0};
        end else begin
            for (int c_idx = 0; c_idx < 3; c_idx = c_idx + 1) begin
                // Stage 2: Reduce 13 elements down to 6 pairs/groups
                stage2_sums[c_idx][0] <= stage1_sums[c_idx][0]  + stage1_sums[c_idx][1];
                stage2_sums[c_idx][1] <= stage1_sums[c_idx][2]  + stage1_sums[c_idx][3];
                stage2_sums[c_idx][2] <= stage1_sums[c_idx][4]  + stage1_sums[c_idx][5];
                stage2_sums[c_idx][3] <= stage1_sums[c_idx][6]  + stage1_sums[c_idx][7];
                stage2_sums[c_idx][4] <= stage1_sums[c_idx][8]  + stage1_sums[c_idx][9];
                stage2_sums[c_idx][5] <= stage1_sums[c_idx][10] + stage1_sums[c_idx][11] + stage1_sums[c_idx][12];

                // Stage 3: Reduce 6 elements down to 3 groups
                stage3_sums[c_idx][0] <= stage2_sums[c_idx][0] + stage2_sums[c_idx][1];
                stage3_sums[c_idx][1] <= stage2_sums[c_idx][2] + stage2_sums[c_idx][3];
                stage3_sums[c_idx][2] <= stage2_sums[c_idx][4] + stage2_sums[c_idx][5];

                // Stage 4: Sum remaining 3 entries to complete individual channels
                stage4_final[c_idx]   <= stage3_sums[c_idx][0] + stage3_sums[c_idx][1] + stage3_sums[c_idx][2];
            end
        end
    end

    // =========================================================================
    // CHANNEL COMBINATION AND BIT QUANTIZATION
    // =========================================================================
    // Combine the 3 filtered structural results together
    wire signed [19:0] total_accum = stage4_final[0] + stage4_final[1] + stage4_final[2];
    
    // Slice off bit resolution according to your fixed point layout [19:6]
    assign conv_out_calc = total_accum[19:6];

    // =========================================================================
    // VALID FLAG CONTROL PIPELINE
    // =========================================================================
    reg [3:0] valid_pipe;

    always @(posedge clk) begin
        if (~rst_n) begin
            valid_pipe <= 4'b0000;
        end else begin
            // Track and filter valid pulse toggle condition matching your internal flag sequence
            if (valid_out_buf)
                valid_pipe[0] <= ~valid_pipe[0];
            
            // Push valid token down through the execution chain stages
            valid_pipe[1] <= valid_pipe[0];
            valid_pipe[2] <= valid_pipe[1];
            valid_pipe[3] <= valid_pipe[2];
        end
    end

    assign valid_out_calc = valid_pipe[3];

endmodule
