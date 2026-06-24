`timescale 1ns / 1ps

module fully_connected
    #(
        parameter INPUT_NUM  = 48, // Total input array neurons
                  OUTPUT_NUM = 10, // Total target classification classes
                  DATA_BITS  = 8   // Bit resolution of trained weights/bias
    )
    (
        input  wire               clk,
        input  wire               rst_n,
        input  wire               valid_in,
        input  wire signed [11:0] data_in_1, data_in_2, data_in_3,
        output wire        [11:0] data_out,
        output wire               valid_out_fc
    );

    localparam INPUT_WIDTH = INPUT_NUM / 3; // 16 parallel load steps

    // State indicators
    reg state; // 0: Buffering input data stream, 1: Running core MAC calculations
    reg [$clog2(INPUT_WIDTH)-1:0] buf_idx;  //Counts 0 to 15
    reg [$clog2(OUTPUT_NUM)-1:0]  out_idx;  //Counts 0 to 9

    // Memory Blocks
    reg signed [13:0]             buffer [0:INPUT_NUM-1];  //buffer holds the 48 image pixels (using 14-bit expanded slots).
    reg signed [DATA_BITS-1:0]    weight [0:INPUT_NUM*OUTPUT_NUM-1]; //weight holds all 480 individual parameters ($48 \times 10$).
    reg signed [DATA_BITS-1:0]    bias   [0:OUTPUT_NUM-1];  //bias holds 10 balancing values (one per class).

    // Pipeline Stage Arrays (Safe extended word sizes to completely eliminate truncation overflows)
    reg signed [21:0] stage1_mult [0:23]; 
    reg signed [21:0] stage1_bias;
    reg signed [22:0] stage2_sums [0:11];
    reg signed [23:0] stage3_sums [0:5];
    reg signed [24:0] stage4_sums [0:2];
    reg signed [26:0] stage5_final;

    // Shift register chain to match pipeline execution delay
    reg [5:0] valid_pipe; 
    reg       calc_trigger; // 1 when the 48*1 buffer is  full 

    // Pre-load parameters from weight files
    initial begin
        $readmemh("fc_weight.mem", weight);
        $readmemh("fc_bias.mem", bias);
    end

    // Input sign extension to 14 bits
    wire signed [13:0] data1 = {{2{data_in_1[11]}}, data_in_1};
    wire signed [13:0] data2 = {{2{data_in_2[11]}}, data_in_2};
    wire signed [13:0] data3 = {{2{data_in_3[11]}}, data_in_3};

    // -------------------------------------------------------------------------
    // CONTROL STATE MACHINE
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (~rst_n) begin
            buf_idx      <= 0;
            out_idx      <= 0;
            state        <= 1'b0;
            calc_trigger <= 1'b0;
            buffer       <= '{default: 14'sd0};
        end
        else begin
            calc_trigger <= 1'b0; // Default pulse floor
            
            if (!state) begin
                if (valid_in) begin
                    buffer[buf_idx]                   <= data1; //brings in the 16 pixels of Channel 0, one by one.
                    buffer[INPUT_WIDTH + buf_idx]     <= data2;  //brings in the 16 pixels of Channel 1, one by one.     
                    buffer[INPUT_WIDTH * 2 + buf_idx] <= data3; //brings in the 16 pixels of Channel 2, one by one.
                    
                    if (buf_idx == INPUT_WIDTH - 1) begin
                        buf_idx      <= 0;
                        state        <= 1'b1; // Memory packed! Handshake calculation engine
                        calc_trigger <= 1'b1;
                    end else begin
                        buf_idx      <= buf_idx + 1'b1;
                    end
                end
            end
            else begin // Core active classification execution loop
                calc_trigger <= 1'b1;
                if (out_idx == OUTPUT_NUM - 1) begin
                    out_idx <= 0;
                    state   <= 1'b0; // Entire 10-class calculation sweep complete
                end else begin
                    out_idx <= out_idx + 1'b1;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // PIPELINED HARDWARE MATH ADDER TREE
    // -------------------------------------------------------------------------
    integer w;
    always @(posedge clk) begin
        if (~rst_n) begin
            stage5_final <= 0;
        end
        else begin
            // Stage 1: Parallel Multiplication (24 Simultaneous Products)
            for (w = 0; w < 24; w = w + 1) begin
                stage1_mult[w] <= weight[out_idx * INPUT_NUM + (w*2)]   * buffer[w*2] + 
                                  weight[out_idx * INPUT_NUM + (w*2+1)] * buffer[w*2+1];
            end
            stage1_bias <= bias[out_idx];

            // Stage 2: Compressing 24 down to 12
            for (w = 0; w < 12; w = w + 1) begin
                stage2_sums[w] <= stage1_mult[w*2] + stage1_mult[w*2+1];
            end

            // Stage 3: Compressing 12 down to 6
            for (w = 0; w < 6; w = w + 1) begin
                stage3_sums[w] <= stage2_sums[w*2] + stage2_sums[w*2+1];
            end

            // Stage 4: Compressing 6 down to 3
            for (w = 0; w < 3; w = w + 1) begin
                stage4_sums[w] <= stage3_sums[w*2] + stage3_sums[w*2+1];
            end

            // Stage 5: Cross-channel final sum with accumulated bias structure
            stage5_final <= stage4_sums[0] + stage4_sums[1] + stage4_sums[2] + stage1_bias;
        end
    end

    // Output bit slice match (Matches your [18:7] fixed-point scale slice)
    assign data_out = stage5_final[18:7];

    // -------------------------------------------------------------------------
    // VALID STROBE PIPELINE DELAY GENERATION
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (~rst_n)
            valid_pipe <= 6'b0;
        else
            valid_pipe <= {valid_pipe[4:0], calc_trigger};
    end

    assign valid_out_fc = valid_pipe[5];

endmodule
