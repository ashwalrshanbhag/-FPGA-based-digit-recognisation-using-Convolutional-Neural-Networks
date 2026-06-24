module conv1_calc
    #(
        parameter WIDTH       = 28, // Input image width
                  HEIGHT      = 28, // Input image height
                  DATA_BITS   = 8,  // Bit-width of raw input pixel data
                  FILTER_SIZE = 5,  // Size of the convolution window (5x5)
                  CHANNEL_LEN = 3   // Number of parallel output channels
    )
    (
        input  wire                 clk,            // Core system clock
        input  wire                 rst_n,          // Active-low asynchronous reset
        input  wire                 valid_out_buf,  // Status flag indicating raw input data window is valid
        
        // Input pixels gathered into an array interface for a 5x5 window (Indices 0 to 24)
        input  wire [DATA_BITS-1:0] data_in [0:FILTER_SIZE*FILTER_SIZE-1],
        
        // Output channels packed into an array interface
        output wire signed [11:0]   conv_out [0:CHANNEL_LEN-1],
        output wire                 valid_out_calc  // High when computation output is valid
    );

    localparam NUM_PRODUCTS = FILTER_SIZE * FILTER_SIZE; // Total multipliers required per channel (25)

    // Memory elements for coefficient parameters (Infers static ROM)
    reg signed [DATA_BITS-1:0] weight [0:CHANNEL_LEN-1][0:NUM_PRODUCTS-1];
    reg signed [DATA_BITS-1:0] bias   [0:CHANNEL_LEN-1];

    // Pipeline tracking register arrays (Eliminates manual tmp0...tmp22 variable naming)
    reg signed [19:0] stage1_reg [0:CHANNEL_LEN-1][0:12]; // Drops 25 products down to 13 values
    reg signed [19:0] stage2_reg [0:CHANNEL_LEN-1][0:5];  // Reduction down to 6 values
    reg signed [19:0] stage3_reg [0:CHANNEL_LEN-1][0:2];  // Reduction down to 3 values
    reg signed [19:0] stage4_reg [0:CHANNEL_LEN-1];       // Final single accumulated scalar sum

    // Datatype parsing signals
    wire signed [DATA_BITS:0] exp_data [0:NUM_PRODUCTS-1]; // Holds 9-bit casted signed pixel data
    wire signed [11:0]        exp_bias [0:CHANNEL_LEN-1];  // Holds sign-extended 12-bit channel biases

    // Control matching delay shift-register pipe (Matches the 4-stage arithmetic latency)
    reg valid_delay_pipe [0:3];

    //--------------------------------------------------------------------------
    // 1. Initial Static ROM Model Variable Sourcing
    //--------------------------------------------------------------------------
    initial begin
        $readmemh("conv1_weight_1.mem", weight[0]);
        $readmemh("conv1_weight_2.mem", weight[1]);
        $readmemh("conv1_weight_3.mem", weight[2]);
        $readmemh("conv1_bias.mem",     bias);
    end

    //--------------------------------------------------------------------------
    // 2. Data Conditioning (Unsigned to Signed & Sign Extensions)
    //--------------------------------------------------------------------------
    genvar p, c;
    generate
        // Convert 8-bit unsigned raw pixel to a 9-bit positive signed equivalent 
        for (p = 0; p < NUM_PRODUCTS; p = p + 1) begin : gen_unsigned_to_signed
            assign exp_data[p] = {1'b0, data_in[p]};
        end

        // Align 8-bit signed biases to match 12-bit math output rules via sign bit replication
        for (c = 0; c < CHANNEL_LEN; c = c + 1) begin : gen_bias_extension
            assign exp_bias[c] = (bias[c][7] == 1'b1) ? {4'b1111, bias[c]} : {4'b0000, bias[c]};
        end
    endgenerate

    //--------------------------------------------------------------------------
    // 3. Parallel Pipelined Computation Engine
    //--------------------------------------------------------------------------
    generate
        for (c = 0; c < CHANNEL_LEN; c = c + 1) begin : gen_channels

            // STAGE 1: Parallel Multiplications & First-Level Pair Additions
            always @(posedge clk or negedge rst_n) begin
                if (~rst_n) begin
                    stage1_reg[c] <= '{default:0}; // Clears complete array slice instantly
                end else begin
                    stage1_reg[c][0]  <= (exp_data[0]  * weight[c][0])  + (exp_data[1]  * weight[c][1]);
                    stage1_reg[c][1]  <= (exp_data[2]  * weight[c][2])  + (exp_data[3]  * weight[c][3]);
                    stage1_reg[c][2]  <= (exp_data[4]  * weight[c][4])  + (exp_data[5]  * weight[c][5]);
                    stage1_reg[c][3]  <= (exp_data[6]  * weight[c][6])  + (exp_data[7]  * weight[c][7]);
                    stage1_reg[c][4]  <= (exp_data[8]  * weight[c][8])  + (exp_data[9]  * weight[c][9]);
                    stage1_reg[c][5]  <= (exp_data[10] * weight[c][10]) + (exp_data[11] * weight[c][11]);
                    stage1_reg[c][6]  <= (exp_data[12] * weight[c][12]) + (exp_data[13] * weight[c][13]);
                    stage1_reg[c][7]  <= (exp_data[14] * weight[c][14]) + (exp_data[15] * weight[c][15]);
                    stage1_reg[c][8]  <= (exp_data[16] * weight[c][16]) + (exp_data[17] * weight[c][17]);
                    stage1_reg[c][9]  <= (exp_data[18] * weight[c][18]) + (exp_data[19] * weight[c][19]);
                    stage1_reg[c][10] <= (exp_data[20] * weight[c][20]) + (exp_data[21] * weight[c][21]);
                    stage1_reg[c][11] <= (exp_data[22] * weight[c][22]) + (exp_data[23] * weight[c][23]);
                    stage1_reg[c][12] <= (exp_data[24] * weight[c][24]); // 25th element has no pair, passes through
                end
            end

            // STAGE 2: Intermediate Reduction (13 Values -> 6 Values)
            always @(posedge clk or negedge rst_n) begin
                if (~rst_n) begin
                    stage2_reg[c] <= '{default:0};
                end else begin
                    stage2_reg[c][0] <= stage1_reg[c][0]  + stage1_reg[c][1];
                    stage2_reg[c][1] <= stage1_reg[c][2]  + stage1_reg[c][3];
                    stage2_reg[c][2] <= stage1_reg[c][4]  + stage1_reg[c][5];
                    stage2_reg[c][3] <= stage1_reg[c][6]  + stage1_reg[c][7];
                    stage2_reg[c][4] <= stage1_reg[c][8]  + stage1_reg[c][9];
                    stage2_reg[c][5] <= stage1_reg[c][10] + stage1_reg[c][11] + stage1_reg[c][12]; // 3-input node
                end
            end

            // STAGE 3: Intermediate Consolidation (6 Values -> 3 Values)
            always @(posedge clk or negedge rst_n) begin
                if (~rst_n) begin
                    stage3_reg[c] <= '{default:0};
                end else begin
                    stage3_reg[c][0] <= stage2_reg[c][0] + stage2_reg[c][1];
                    stage3_reg[c][1] <= stage2_reg[c][2] + stage2_reg[c][3];
                    stage3_reg[c][2] <= stage2_reg[c][4] + stage2_reg[c][5];
                end
            end

            // STAGE 4: Final Dot Product Matrix Accumulation (3 Values -> 1 Scalar)
            always @(posedge clk or negedge rst_n) begin
                if (~rst_n) begin
                    stage4_reg[c] <= 20'd0;
                end else begin
                    stage4_reg[c] <= stage3_reg[c][0] + stage3_reg[c][1] + stage3_reg[c][2];
                end
            end

            // OUTPUT QUANTIZATION: Drops lower 8 fractional bits (Fixed-point shift) and injects bias values
            assign conv_out[c] = stage4_reg[c][19:8] + exp_bias[c];

        end
    endgenerate

    //--------------------------------------------------------------------------
    // 4. Control Logic Latency Delay Synchronization
    //--------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n) begin
            valid_delay_pipe <= '{default:0};
        end else begin
            valid_delay_pipe[0] <= valid_out_buf;
            valid_delay_pipe[1] <= valid_delay_pipe[0];
            valid_delay_pipe[2] <= valid_delay_pipe[1];
            valid_delay_pipe[3] <= valid_delay_pipe[2]; // Latency step 4 tracks exact arrival of valid math data
        end
    end

    assign valid_out_calc = valid_delay_pipe[3];

endmodule
