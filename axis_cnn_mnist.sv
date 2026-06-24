`timescale 1ns / 1ps

module axis_cnn_mnist (
    input  logic       aclk,
    input  logic       aresetn,
    output logic       s_axis_tready, // Input Ready: Tells the sender "I am ready for pixels!"
    input  logic [7:0] s_axis_tdata, // Input Data: The incoming 8-bit pixel value.
    input  logic       s_axis_tvalid, // Input Valid: Sender says "The pixel on tdata is real!"
    input  logic       m_axis_tready, // Output Ready: Next chip says "Ready for your AI prediction!"
    output logic [7:0] m_axis_tdata, // Output Data: The final 8-bit AI prediction (0-9).
    output logic       m_axis_tvalid,// Output Valid: We say "Our AI prediction is ready!"
    output logic       m_axis_tlast
);

    // Structural Interconnect Wires
    logic signed [11:0] conv_out_1, conv_out_2, conv_out_3;
    logic signed [11:0] conv2_out_1, conv2_out_2, conv2_out_3;
    logic signed [11:0] max_value_1, max_value_2, max_value_3;
    logic signed [11:0] max2_value_1, max2_value_2, max2_value_3;
    logic signed [11:0] fc_out_data;

    logic valid_out_1, valid_out_2, valid_out_3, valid_out_4, valid_out_5, valid_out_6;
    logic [3:0]  decision;
    
    // Internal Control Registers
    logic [7:0]  s_axis_tdata_reg;
    logic        s_axis_tvalid_reg;
    logic        s_axis_tvalid_tick;
    logic [10:0] cnt_sequencer_reg;
    logic        valid_in;
    logic        clr;

    // -------------------------------------------------------------------------
    // HARDWARE ACCELERATOR PIPELINE INSTANTIATION
    // -------------------------------------------------------------------------
    
    conv1_layer conv1_layer_inst (
        .clk(aclk),
        .rst_n(aresetn & clr),
        .valid_in(valid_in),
        .data_in(s_axis_tdata_reg),
        .conv_out_1,
        .conv_out_2,
        .conv_out_3,
        .valid_out_conv(valid_out_1)
    );

    maxpool_relu #(
        .CONV_BIT(12),
        .HALF_WIDTH(12),
        .HALF_HEIGHT(12),
        .HALF_WIDTH_BIT(4)
    ) maxpool_relu_1 (
        .clk(aclk),
        .rst_n(aresetn & clr),
        .valid_in(valid_out_1),
        .conv_out_1, .conv_out_2, .conv_out_3,
        .max_value_1, .max_value_2, .max_value_3,
        .valid_out_relu(valid_out_2)
    );

    conv2_layer conv2_layer_inst (
        .clk(aclk),
        .rst_n(aresetn & clr),
        .valid_in(valid_out_2),
        .max_value_1, .max_value_2, .max_value_3,
        .conv2_out_1, .conv2_out_2, .conv2_out_3,
        .valid_out_conv2(valid_out_3)
    );

    maxpool_relu #(
        .CONV_BIT(12),
        .HALF_WIDTH(4),
        .HALF_HEIGHT(4),
        .HALF_WIDTH_BIT(3)
    ) maxpool_relu_2 (
        .clk(aclk),
        .rst_n(aresetn & clr),
        .valid_in(valid_out_3),
        .conv_out_1(conv2_out_1), .conv_out_2(conv2_out_2), .conv_out_3(conv2_out_3),
        .max_value_1(max2_value_1), .max_value_2(max2_value_2), .max_value_3(max2_value_3),
        .valid_out_relu(valid_out_4)
    );

    fully_connected #(
        .INPUT_NUM(48),
        .OUTPUT_NUM(10),
        .DATA_BITS(8)
    ) fully_connected_inst (
        .clk(aclk),
        .rst_n(aresetn & clr),
        .valid_in(valid_out_4),
        .data_in_1(max2_value_1), .data_in_2(max2_value_2), .data_in_3(max2_value_3),
        .data_out(fc_out_data),
        .valid_out_fc(valid_out_5)
    );

    comparator comparator_inst (
        .clk(aclk),
        .rst_n(aresetn & clr),
        .valid_in(valid_out_5),
        .data_in(fc_out_data),
        .decision,
        .valid_out(valid_out_6)
    );
    
    // -------------------------------------------------------------------------
    // INPUT BUFFERING & CONTROL LOGIC
    // -------------------------------------------------------------------------
    
    // Synchronous Pipeline Input Registers
    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            s_axis_tdata_reg  <= 8'd0;
            s_axis_tvalid_reg <= 1'b0;
        end else begin
            s_axis_tdata_reg  <= s_axis_tdata;
            s_axis_tvalid_reg <= s_axis_tvalid;
        end
    end   
    
    // Rising Edge Strobe Detection for Incoming Stream
    assign s_axis_tvalid_tick = s_axis_tvalid & ~s_axis_tvalid_reg;
    
    // Global Hardware Lifecycle Sequencer
    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            cnt_sequencer_reg <= 11'd0;
        end else if (s_axis_tvalid_tick) begin
            cnt_sequencer_reg <= 11'd1;
        // Continuous countdown window tracking pipeline latency
        end else if (cnt_sequencer_reg >= 11'd1 && cnt_sequencer_reg <= 11'd1280) begin
            cnt_sequencer_reg <= cnt_sequencer_reg + 11'd1;
        end else if (cnt_sequencer_reg >= 11'd1281) begin
            cnt_sequencer_reg <= 11'd0;
        end
    end
    
    // -------------------------------------------------------------------------
    // SYSTEM ROUTING & HANDSHAKE SIGNALS
    // -------------------------------------------------------------------------
    assign s_axis_tready = !((cnt_sequencer_reg >= 11'd784) && (cnt_sequencer_reg <= 11'd1281));
    assign valid_in      = (cnt_sequencer_reg >= 11'd1)   && (cnt_sequencer_reg <= 11'd841);
    assign m_axis_tdata  = {4'b0000, decision};
    assign m_axis_tvalid = (valid_out_6) && (cnt_sequencer_reg == 11'd1279);
    assign m_axis_tlast  = (valid_out_6) && (cnt_sequencer_reg == 11'd1279);
    assign clr           = (cnt_sequencer_reg != 11'd1280);

endmodule
