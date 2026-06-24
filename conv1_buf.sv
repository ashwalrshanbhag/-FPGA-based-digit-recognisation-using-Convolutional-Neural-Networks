`timescale 1ns / 1ps

module conv1_buf
    #(
        parameter WIDTH       = 28, // Input image width
                  HEIGHT      = 28, // Input image height
                  DATA_BITS   = 8,  // Bit-width of pixel data
                  FILTER_SIZE = 5   // Size of the convolution matrix (5x5)
    )
    (
        input  wire                   clk,
        input  wire                   rst_n,
        input  wire                   valid_in, // high when pixel is running 
        input  wire [DATA_BITS-1:0]   data_in, // incoming single pixel stream 
        // Using a clean 2D array packed port instead of 25 standalone outputs
        output reg  [DATA_BITS-1:0]   data_out [0:FILTER_SIZE*FILTER_SIZE-1],  
        output reg                    valid_out_buf  // High when a full 5x5 window is ready
    );

    // Size of the ring buffer holding exactly FILTER_SIZE image lines  28*5 = 140 
    localparam BUF_SIZE = WIDTH * FILTER_SIZE;

    // The physical RAM/buffer storage block inside the FPGA
    reg [DATA_BITS-1:0] buffer [0:BUF_SIZE-1];
    reg [$clog2(BUF_SIZE)-1:0] buf_idx;       // Track where incoming data is written (0 to 139)
    reg [$clog2(WIDTH)-1:0]    w_idx;         // Current X coordinate of sliding window (0 to 27)
    reg [$clog2(HEIGHT)-1:0]   h_idx;        // Current Y coordinate of sliding window (0 to 27)
    reg [2:0]                  buf_flag;      // Pointer tracking which row is "top" (0 to 4)
    reg                        state;         // 0: filling buffer, 1: streaming windows

    // Variables for loop iteration inside procedural blocks
    integer r, c; 

    // Ring Buffer Input & Tracking Controller
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n) begin
            buf_idx       <= 0;
            w_idx         <= 0;
            h_idx         <= 0;
            buf_flag      <= 0;
            state         <= 1'b0;
            valid_out_buf <= 1'b0;
            
            // SystemVerilog array clearing shortcut syntax
            buffer        <= '{default: 0};
            data_out      <= '{default: 0};
        end 
        else if (valid_in) begin
            // Store the incoming pixel into our 140-pixel reservoir
            buffer[buf_idx] <= data_in;

           // Increment our write pointer and wrap around at 139
            if (buf_idx == BUF_SIZE - 1)
                buf_idx <= 0;
            else
                buf_idx <= buf_idx + 1'b1;

           // If we are still filling up the reservoir...
            if (!state) begin
                // Check if we just hit the 140th pixel (reservoir full!)    
                if (buf_idx == BUF_SIZE - 1) begin
                    state <= 1'b1;
                end
            end 
            else begin // State == 1 (Valid Frame Window generation)
                w_idx <= w_idx + 1'b1; // Shift sliding window right by 1 column

                // Boundary Check: If the window hits the right edge of the image
                if (w_idx == WIDTH - FILTER_SIZE + 1) begin
                    valid_out_buf <= 1'b0; // Turn off flag: window is falling off the image edge
                end 
                else if (w_idx == WIDTH - 1) begin
                    w_idx <= 0;  // Wrap X coordinate back to the left side
                    
                    // Increment row flag mapping because row 0 wrapped to become the bottom row
                    if (buf_flag == FILTER_SIZE - 1)
                        buf_flag <= 0;
                    else
                        buf_flag <= buf_flag + 1'b1;  //Physical Row Index = (r + buf-flag ) 

                    // Frame Complete Check: Have we processed the entire 28x28 image?
                    if (h_idx == HEIGHT - FILTER_SIZE) begin
                        h_idx <= 0;
                        state <= 1'b0; // Reset state machine to wait for next image frame
                    end else begin
                        h_idx <= h_idx + 1'b1;
                    end
                end 
                else if (w_idx == 0) begin
                    valid_out_buf <= 1'b1; // Flag high: back into valid pixel tracking territory
                end

                // 4. Elegant Window Selection Logic (Mathematical Mapping replacement)
                // Instantly grabs the 5x5 window elements out of memory based on row rotation
                //converting 5*5 into 25*1
                for (r = 0; r < FILTER_SIZE; r = r + 1) begin
                    for (c = 0; c < FILTER_SIZE; c = c + 1) begin
                        // This math computes the physical row translation index under wrap-around rotation conditions
                        data_out[r*FILTER_SIZE + c] <= buffer[w_idx + c + (WIDTH * ((r + buf_flag) % FILTER_SIZE))];
                    )
                end

            end
        end
    end

endmodule
