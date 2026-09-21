`timescale 1ns/1ps
`default_nettype none

// Minimal frequency-domain source for testing a 64-point Xilinx IFFT.
// Bin 1 contains a real-valued tone; all other bins are zero.
// TDATA packing: {imag[15:0], real[15:0]}.
module ifft_test_source #(
  parameter integer STARTUP_CYCLES = 16,
  parameter [15:0]  TONE_AMPLITUDE = 16'h4000
) (
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME ACLK, ASSOCIATED_BUSIF M_AXIS_DATA, ASSOCIATED_RESET ARESETN" *)
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 ACLK CLK" *)
  input  wire        aclk,

  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME ARESETN, POLARITY ACTIVE_LOW" *)
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 ARESETN RST" *)
  input  wire        aresetn,

  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME M_AXIS_DATA, TDATA_NUM_BYTES 4, HAS_TREADY 1, HAS_TLAST 1" *)
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_DATA TDATA" *)
  output wire [31:0] m_axis_data_tdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_DATA TVALID" *)
  output wire        m_axis_data_tvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_DATA TREADY" *)
  input  wire        m_axis_data_tready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_DATA TLAST" *)
  output wire        m_axis_data_tlast
);

  reg [5:0] bin_index;
  reg [7:0] startup_count;
  reg       active;

  wire transfer = m_axis_data_tvalid && m_axis_data_tready;

  assign m_axis_data_tvalid = active;
  assign m_axis_data_tlast  = active && (bin_index == 6'd63);
  assign m_axis_data_tdata  = (bin_index == 6'd1)
                              ? {16'h0000, TONE_AMPLITUDE}
                              : 32'h00000000;

  always @(posedge aclk) begin
    if (!aresetn) begin
      bin_index     <= 6'd0;
      startup_count <= 8'd0;
      active        <= 1'b0;
    end else if (!active) begin
      if (startup_count == STARTUP_CYCLES - 1) begin
        active    <= 1'b1;
        bin_index <= 6'd0;
      end else begin
        startup_count <= startup_count + 1'b1;
      end
    end else if (transfer) begin
      if (bin_index == 6'd63)
        bin_index <= 6'd0;
      else
        bin_index <= bin_index + 1'b1;
    end
  end

endmodule

`default_nettype wire
