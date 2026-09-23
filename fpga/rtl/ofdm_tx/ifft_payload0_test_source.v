`timescale 1ns/1ps
`default_nettype none

// Stage 1 bring-up source: feeds xfft_0 the exact 64-point frequency-domain
// spectrum that ofdm/core.py's _make_payload_symbol() builds for Payload #0
// of the README example message "HELLO OFDM - ZedBoard AD9361" (first 12
// bytes of the packed packet: MAGIC + LENGTH + "HELLO OF").
//
// Values are Q1.15 fixed point (same convention as ifft_test_source.v),
// rounded to the nearest int16 from the float64 values python/README.md
// section 2.2 prints. TDATA packing: {imag[15:0], real[15:0]}.
//
// Purpose: drive xfft_0 with a known, non-trivial vector and compare its
// 64-point time-domain output against the quantized-input IFFT computed in
// Python (see python/README.md 2.2 / the golden dump used to build this
// file) -- this is Stage 1 of the TX-IFFT-to-PL migration in
// python/README.md's roadmap: verify IFFT alone, before adding CP (Stage 2)
// or moving QPSK mapping into hardware (Stage 3).
module ifft_payload0_test_source #(
  parameter integer STARTUP_CYCLES = 16
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

  reg [31:0] rom [0:63];

  initial begin
    rom[ 0] = 32'h0000_0000; rom[ 1] = 32'ha57e_5a82; rom[ 2] = 32'h5a82_5a82; rom[ 3] = 32'ha57e_a57e;
    rom[ 4] = 32'h5a82_5a82; rom[ 5] = 32'ha57e_5a82; rom[ 6] = 32'h5a82_5a82; rom[ 7] = 32'h0000_7fff;
    rom[ 8] = 32'ha57e_a57e; rom[ 9] = 32'h5a82_5a82; rom[10] = 32'ha57e_5a82; rom[11] = 32'h5a82_5a82;
    rom[12] = 32'ha57e_a57e; rom[13] = 32'ha57e_a57e; rom[14] = 32'h5a82_5a82; rom[15] = 32'h5a82_a57e;
    rom[16] = 32'h5a82_5a82; rom[17] = 32'h5a82_5a82; rom[18] = 32'ha57e_5a82; rom[19] = 32'h5a82_5a82;
    rom[20] = 32'ha57e_a57e; rom[21] = 32'h0000_8000; rom[22] = 32'ha57e_a57e; rom[23] = 32'ha57e_5a82;
    rom[24] = 32'h5a82_5a82; rom[25] = 32'ha57e_5a82; rom[26] = 32'h5a82_a57e; rom[27] = 32'h0000_0000;
    rom[28] = 32'h0000_0000; rom[29] = 32'h0000_0000; rom[30] = 32'h0000_0000; rom[31] = 32'h0000_0000;
    rom[32] = 32'h0000_0000; rom[33] = 32'h0000_0000; rom[34] = 32'h0000_0000; rom[35] = 32'h0000_0000;
    rom[36] = 32'h0000_0000; rom[37] = 32'h0000_0000; rom[38] = 32'ha57e_5a82; rom[39] = 32'h5a82_5a82;
    rom[40] = 32'ha57e_a57e; rom[41] = 32'ha57e_a57e; rom[42] = 32'ha57e_5a82; rom[43] = 32'h0000_7fff;
    rom[44] = 32'h5a82_5a82; rom[45] = 32'ha57e_5a82; rom[46] = 32'h5a82_a57e; rom[47] = 32'h5a82_5a82;
    rom[48] = 32'h5a82_5a82; rom[49] = 32'h5a82_5a82; rom[50] = 32'h5a82_5a82; rom[51] = 32'h5a82_5a82;
    rom[52] = 32'ha57e_5a82; rom[53] = 32'ha57e_a57e; rom[54] = 32'h5a82_5a82; rom[55] = 32'ha57e_5a82;
    rom[56] = 32'h5a82_5a82; rom[57] = 32'h0000_7fff; rom[58] = 32'h5a82_a57e; rom[59] = 32'h5a82_5a82;
    rom[60] = 32'ha57e_5a82; rom[61] = 32'h5a82_5a82; rom[62] = 32'ha57e_5a82; rom[63] = 32'ha57e_5a82;
  end

  reg [5:0] bin_index;
  reg [7:0] startup_count;
  reg       active;

  wire transfer = m_axis_data_tvalid && m_axis_data_tready;

  assign m_axis_data_tvalid = active;
  assign m_axis_data_tlast  = active && (bin_index == 6'd63);
  assign m_axis_data_tdata  = rom[bin_index];

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
