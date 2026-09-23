`timescale 1ns/1ps
`default_nettype none

// Sends the fixed 64-point IFFT configuration after reset, and again every
// time `resend` pulses (driven from ofdm_frame_sequencer_0/train_enable) --
// the config word never changes, but resending it on every training symbol
// means a live ILA capture has many chances to catch the transfer instead
// of needing to race a power-on reset that only gives one shot.
//   bit 0    : FWD_INV   = 0 (inverse FFT)
//   bits 6:1 : SCALE_SCH = 2'b10, 2'b10, 2'b10 (/64 total)
//   bit 7    : unused    = 0
module fft_config (
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME ACLK, ASSOCIATED_BUSIF M_AXIS_CONFIG, ASSOCIATED_RESET ARESETN" *)
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 ACLK CLK" *)
  input  wire       aclk,

  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME ARESETN, POLARITY ACTIVE_LOW" *)
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 ARESETN RST" *)
  input  wire       aresetn,

  // Re-arms the one-shot send below on every rising edge.
  input  wire       resend,

  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME M_AXIS_CONFIG, TDATA_NUM_BYTES 1, HAS_TREADY 1" *)
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_CONFIG TDATA" *)
  output wire [7:0] m_axis_config_tdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_CONFIG TVALID" *)
  output reg        m_axis_config_tvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_CONFIG TREADY" *)
  input  wire       m_axis_config_tready
);

  localparam [7:0] FFT_CONFIG = 8'h54;
  reg config_sent;
  reg resend_prev;
  wire resend_rising = resend && !resend_prev;

  assign m_axis_config_tdata = FFT_CONFIG;

  always @(posedge aclk) begin
    if (!aresetn) begin
      m_axis_config_tvalid <= 1'b0;
      config_sent         <= 1'b0;
      resend_prev         <= 1'b0;
    end else begin
      resend_prev <= resend;
      if (resend_rising) begin
        config_sent <= 1'b0;
      end

      if (!config_sent) begin
        m_axis_config_tvalid <= 1'b1;
        if (m_axis_config_tvalid && m_axis_config_tready) begin
          m_axis_config_tvalid <= 1'b0;
          config_sent         <= 1'b1;
        end
      end else begin
        m_axis_config_tvalid <= 1'b0;
      end
    end
  end

endmodule

`default_nettype wire
