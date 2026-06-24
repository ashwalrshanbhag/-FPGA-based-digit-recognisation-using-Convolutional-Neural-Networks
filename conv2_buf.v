`timescale 1ns / 1ps

module conv2_buf
    #(
        parameter WIDTH     = 12, // Input map width (scaled down for layer 2)
                  HEIGHT    = 12, // Input map height
                  DATA_BITS = 12  // Increased resolution bit-width
    )
    (
        input  wire                   clk,
        input  wire                   rst_n,
        input  wire                   valid_in,
        input  wire [DATA_BITS-1:0]   data_in,
        
        // Premium 2D Array Port replacing all 25 individual outputs
        output reg  [DATA_BITS-1:0]   data_out [0:24], 
        output reg                    valid_out_buf
    );

    // Fixed architecture parameter for a 5x5 convolution
    localparam FILTER_SIZE = 5;
    localparam BUF_SIZE    = WIDTH * FILTER_SIZE;

    // Internal Memory Reservoir
    reg [DATA_BITS-1:0] buffer [0:BUF_SIZE-1];

    // Smart-sized tracking counters using $clog2
    reg [$clog2(BUF_SIZE)-1:0] buf_idx;   // Safely scales pointer width for 1D buffer
    reg [$clog2(WIDTH)-1:0]    w_idx;     // X coordinate tracker
    reg [$clog2(HEIGHT)-1:0]   h_idx;     // Y coordinate tracker
    reg [2:0]                  buf_flag;  // Circular row tracker (0 to 4)
    reg                        state;     // 0: Filling reservoir, 1: Active streaming

    // Loop variables for hardware generation
    integer r, c;

    // Main Control & Data Stream Sequencer
    always @(posedge clk) begin
        if (~rst_n) begin
            // Complete state resets
            buf_idx       <= 0;
            w_idx         <= 0;
            h_idx         <= 0;
            buf_flag      <= 0;
            state         <= 1'b0;
            valid_out_buf <= 1'b0;
            
            // Clean SystemVerilog full array clears
            buffer        <= '{default: 0};
            data_out      <= '{default: 0};
        end 
        else if (valid_in) begin
            // 1. Capture streaming data into ring memory
            buffer[buf_idx] <= data_in;

            // Increment binary pointer address
            if (buf_idx == BUF_SIZE - 1)
                buf_idx <= 0;
            else
                buf_idx <= buf_idx + 1'b1;

            // 2. Control Machine State Checking
            if (!state) begin
                if (buf_idx == BUF_SIZE - 1) begin
                    state <= 1'b1; // Memory is full, start calculation stream
                end
            end 
            else begin // state == 1
                w_idx <= w_idx + 1'b1; // Shift sliding window right by 1 column

                // 3. Horizontal & Vertical Edge Tracking Boundary Conditions
                if (w_idx == WIDTH - FILTER_SIZE + 1) begin
                    valid_out_buf <= 1'b0; // Turn off output flag: window hits right invalid margin
                end 
                else if (w_idx == WIDTH - 1) begin
                    w_idx <= 0; // Wrap X back to left edge
                    
                    // Increment row flag mapping because row wrapped around
                    if (buf_flag == FILTER_SIZE - 1)
                        buf_flag <= 0;
                    else
                        buf_flag <= buf_flag + 1'b1;

                    // Entire image map frame complete condition
                    if (h_idx == HEIGHT - FILTER_SIZE) begin
                        h_idx <= 0;
                        state <= 1'b0; // Reset state machine to wait for next image frame
                    end else begin
                        h_idx <= h_idx + 1'b1;
                    end
                end 
                else if (w_idx == 0) begin
                    valid_out_buf <= 1'b1; // Back into valid pixel territory
                end

                // 4. Mathematical 5x5 Flattening Vector Rotation Loop
                // Replaces all 150 lines of manual assignment statements
                for (r = 0; r < FILTER_SIZE; r = r + 1) begin
                    for (c = 0; c < FILTER_SIZE; c = c + 1) begin
                        // Map 2D matrix (r,c) to flat 1D vector (0-24) using circular row offset
                        data_out[r*FILTER_SIZE + c] <= buffer[w_idx + c + (WIDTH * ((r + buf_flag) % FILTER_SIZE))];
                    end
                end

            end
        end
    end

endmodule
