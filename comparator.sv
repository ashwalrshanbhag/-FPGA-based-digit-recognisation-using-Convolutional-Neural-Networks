`timescale 1ns / 1ps

module comparator
    (
        input  wire        clk,
        input  wire        rst_n,
        input  wire        valid_in,
        input  wire [11:0] data_in,
        output reg  [3:0]  decision,
        output reg         valid_out
    );

    // 10-slot reservoir buffer to store the input features
    reg signed [11:0] buffer [0:9];
    reg [3:0]  buf_idx;
    reg [2:0]  delay_cnt;
    reg        state;

    // Internal wires for the combinational comparison layers
    wire signed [11:0] cmp1_0, cmp1_1, cmp1_2, cmp1_3, cmp1_4;
    wire signed [11:0] cmp2_0, cmp2_1, cmp2_2;
    wire signed [11:0] cmp3_0, cmp3_1;
    wire signed [11:0] final_max;

    // -------------------------------------------------------------------------
    // HARDWARE COMPARATOR TREE (Pure Combinational - Resolves Instantly)
    // -------------------------------------------------------------------------
    // Layer 1: 10 Elements down to 5
    assign cmp1_0 = (buffer[0] >= buffer[1]) ? buffer[0] : buffer[1];
    assign cmp1_1 = (buffer[2] >= buffer[3]) ? buffer[2] : buffer[3];
    assign cmp1_2 = (buffer[4] >= buffer[5]) ? buffer[4] : buffer[5];
    assign cmp1_3 = (buffer[6] >= buffer[7]) ? buffer[6] : buffer[7];
    assign cmp1_4 = (buffer[8] >= buffer[9]) ? buffer[8] : buffer[9];

    // Layer 2: 5 Elements down to 3
    assign cmp2_0 = (cmp1_0 >= cmp1_1) ? cmp1_0 : cmp1_1;
    assign cmp2_1 = (cmp1_2 >= cmp1_3) ? cmp1_2 : cmp1_3;
    assign cmp2_2 = cmp1_4; // Odd element passes through

    // Layer 3: 3 Elements down to 2
    assign cmp3_0 = (cmp2_0 >= cmp2_1) ? cmp2_0 : cmp2_1;
    assign cmp3_1 = cmp2_2; // Odd element passes through

    // Layer 4: Final absolute maximum
    assign final_max = (cmp3_0 >= cmp3_1) ? cmp3_0 : cmp3_1;

    // -------------------------------------------------------------------------
    // SEQUENTIAL CONTROL MACHINE
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (~rst_n) begin
            valid_out  <= 1'b0;
            buf_idx    <= 4'd0;
            delay_cnt  <= 3'd0;
            state      <= 1'b0;
            decision   <= 4'd0;
            buffer     <= '{default: 12'sd0}; // SystemVerilog full array clear
        end
        else begin
            if (valid_in) begin
                buffer[buf_idx] <= data_in;
                valid_out       <= 1'b0; // Suppress output strobe while loading
                
                if (buf_idx == 4'd9) begin
                    buf_idx <= 4'd0;
                    state   <= 1'b1; // Buffer full! Trigger processing state
                end else begin
                    buf_idx <= buf_idx + 1'b1;
                end
            end
            else if (state) begin
                delay_cnt <= delay_cnt + 1'b1;
                
                // Since the tree is combinational, it settles instantly. 
                // We pulse valid_out and register the decision on the next clock cycle.
                if (delay_cnt == 3'd1) begin
                    valid_out <= 1'b1;
                    state     <= 1'b0; // Reset execution flag
                    delay_cnt <= 3'd0;
                    
                    // Priority Encoder to map the winning maximum to its channel address index
                    if      (final_max == buffer[0]) decision <= 4'd0;
                    else if (final_max == buffer[1]) decision <= 4'd1;
                    else if (final_max == buffer[2]) decision <= 4'd2;
                    else if (final_max == buffer[3]) decision <= 4'd3;
                    else if (final_max == buffer[4]) decision <= 4'd4;
                    else if (final_max == buffer[5]) decision <= 4'd5;
                    else if (final_max == buffer[6]) decision <= 4'd6;
                    else if (final_max == buffer[7]) decision <= 4'd7;
                    else if (final_max == buffer[8]) decision <= 4'd8;
                    else                             decision <= 4'd9;
                end
            end
            else begin
                valid_out <= 1'b0;
            end
        end
    end

endmodule
