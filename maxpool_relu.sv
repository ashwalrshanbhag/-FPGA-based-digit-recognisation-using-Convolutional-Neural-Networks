`timescale 1ns / 1ps

module maxpool_relu
    #(
        parameter int CONV_BIT        = 12,  // Input bit-width from convolution layer
        parameter int HALF_WIDTH      = 12,
        parameter int HALF_HEIGHT     = 12,
        parameter int HALF_WIDTH_BIT  = 4
    )
    (
        input  wire                         clk,
        input  wire                         rst_n,
        input  wire                         valid_in,  // High when valid pixel data arrives
        
        // Input Channels: Pack 3 separate parallel streams into a 2D array [0:2]
        input  wire signed [CONV_BIT-1:0]   conv_out [0:2],  
        // Output Channels: 3 parallel activated streams after Pooling + ReLU
        output reg         [CONV_BIT-1:0]   max_value [0:2],
        output reg                          valid_out_relu  // Strobe indicating valid output data
    );

    // 2D Line Buffer: 3 channels by HALF_WIDTH elements
    reg signed [CONV_BIT-1:0] row_buffer [0:2][0:HALF_WIDTH-1];

    reg [HALF_WIDTH_BIT-1:0] pcount;
    reg                      state; // 0: Top Row, 1: Bottom Row
    reg                      flag;  // 0: Left Column, 1: Right Column

    // Pre-calculated comparison winners for clean indexing
    logic signed [CONV_BIT-1:0] current_max [0:2];

    always_ff @(posedge clk) begin
        if (~rst_n) begin
            row_buffer     <= '{default: '{default: 0}};
            max_value      <= '{default: 0};
            valid_out_relu <= 1'b0;
            pcount         <= '0;
            state          <= 1'b0;
            flag           <= 1'b0;
        end else begin
            if (valid_in) begin
                flag <= ~flag;
                
                // Track Horizontal position and Row States
                if (flag == 1'b1) begin
                    pcount <= pcount + 1'b1;
                    if (pcount == (HALF_WIDTH-1)) begin
                        state  <= ~state;
                        pcount <= '0;
                    end
                end

                // Process all 3 channels simultaneously using a structured loop
                for (int ch = 0; ch < 3; ch++) begin
                    if (state == 1'b0) begin
                        // -----------------------------------------------------
                        // ROW 1: Accumulating the top half of the 2x2 window
                        // -----------------------------------------------------
                        valid_out_relu <= 1'b0;
                        if (flag == 1'b0) begin
                            // First pixel: Just latch it into the line buffer
                            row_buffer[ch][pcount] <= conv_out[ch];
                        end else begin
                            // Second pixel: Compare with first pixel and save winner
                            if (row_buffer[ch][pcount] < conv_out[ch]) begin
                                row_buffer[ch][pcount] <= conv_out[ch];
                            end
                        end
                    end else begin
                        // -----------------------------------------------------
                        // ROW 2: Evaluating the bottom half and applying ReLU
                        // -----------------------------------------------------
                        if (flag == 1'b0) begin
                            // Third pixel: Compare with Row 1 winner
                            valid_out_relu <= 1'b0;
                            if (row_buffer[ch][pcount] < conv_out[ch]) begin
                                row_buffer[ch][pcount] <= conv_out[ch];
                            end
                        end else begin
                            // Fourth pixel: Final comparison of all 4 points + ReLU Activation
                            valid_out_relu <= 1'b1;
                            
                            // Determine the absolute max value among all 4 entries
                            if (row_buffer[ch][pcount] < conv_out[ch]) begin
                                current_max[ch] = conv_out[ch];
                            end else begin
                                current_max[ch] = row_buffer[ch][pcount];
                            end

                            // Fused ReLU Equation: max(0, current_max)
                            if (current_max[ch] > 0) begin
                                max_value[ch] <= current_max[ch];
                            end else begin
                                max_value[ch] <= '0; // Clamp negative features to zero
                            end
                        end
                    end
                end // end channel loop
                
            end else begin
                valid_out_relu <= 1'b0;
            end
        end
    end

endmodule
