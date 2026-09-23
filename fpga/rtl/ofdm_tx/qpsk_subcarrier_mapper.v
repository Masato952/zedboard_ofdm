`timescale 1ns/1ps
`default_nettype none

// Stage 3/4 of the TX-IFFT-to-PL migration (see python/README.md roadmap):
// QPSK-maps and places 96 raw payload bits onto the 64-point spectrum *in
// hardware*, instead of Python doing the mapping and handing over the
// finished spectrum. The bits themselves now come from ofdm_payload_regs.v
// (an AXI-Lite register file software writes), not a fixed localparam --
// Stage 3 verified this module's logic against a hardcoded Payload #0 of
// "HELLO OFDM - ZedBoard AD9361" (byte-for-byte identical to the Stage 2
// ILA capture); Stage 4 only swapped where payload_bits comes from.
module qpsk_subcarrier_mapper #(
  parameter integer NFFT            = 64,
  parameter integer STARTUP_CYCLES  = 16
) (
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME ACLK, ASSOCIATED_BUSIF M_AXIS_DATA, ASSOCIATED_RESET ARESETN" *)
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 ACLK CLK" *)
  input  wire        aclk,

  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME ARESETN, POLARITY ACTIVE_LOW" *)
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 ARESETN RST" *)
  input  wire        aresetn,

  // 96 raw payload bits for whichever symbol ofdm_frame_regs.v currently
  // has selected (its symbol_index input, driven by the frame sequencer).
  // Sampled once per symbol restart (bin_index wraps to 0).
  input  wire [95:0] payload_bits,

  // Gates this module on/off for the frame sequencer (Stage 5): held low,
  // the module parks at bin_index=0/inactive and produces nothing, so it
  // can share xfft_0 with training_symbol_source.v without both running
  // at once. Tied to 1'b1 this behaves exactly as it did in Stage 3/4.
  input  wire         enable,

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

  // payload_bits[95:0]: bit[95] is the first bit, bit[0] the last (same
  // order np.unpackbits produces). Symbol i (i=0..47) is mapped from bits
  // (2i, 2i+1). Driven live by ofdm_payload_regs.v.

  // Per-bin routing, mirrors _bin_index(data_k)/_bin_index(pilot_k):
  //   0..47 = data symbol index S0..S47
  //   48    = fixed pilot value +1
  //   49    = fixed pilot value -1
  //   63    = zero (DC / guard band) -- reused as the "don't care" code
  reg [5:0] bin_map [0:NFFT-1];
  initial begin
    bin_map[ 0]=6'd63; bin_map[ 1]=6'd24; bin_map[ 2]=6'd25; bin_map[ 3]=6'd26;
    bin_map[ 4]=6'd27; bin_map[ 5]=6'd28; bin_map[ 6]=6'd29; bin_map[ 7]=6'd48;
    bin_map[ 8]=6'd30; bin_map[ 9]=6'd31; bin_map[10]=6'd32; bin_map[11]=6'd33;
    bin_map[12]=6'd34; bin_map[13]=6'd35; bin_map[14]=6'd36; bin_map[15]=6'd37;
    bin_map[16]=6'd38; bin_map[17]=6'd39; bin_map[18]=6'd40; bin_map[19]=6'd41;
    bin_map[20]=6'd42; bin_map[21]=6'd49; bin_map[22]=6'd43; bin_map[23]=6'd44;
    bin_map[24]=6'd45; bin_map[25]=6'd46; bin_map[26]=6'd47; bin_map[27]=6'd63;
    bin_map[28]=6'd63; bin_map[29]=6'd63; bin_map[30]=6'd63; bin_map[31]=6'd63;
    bin_map[32]=6'd63; bin_map[33]=6'd63; bin_map[34]=6'd63; bin_map[35]=6'd63;
    bin_map[36]=6'd63; bin_map[37]=6'd63; bin_map[38]=6'd0;  bin_map[39]=6'd1;
    bin_map[40]=6'd2;  bin_map[41]=6'd3;  bin_map[42]=6'd4;  bin_map[43]=6'd48;
    bin_map[44]=6'd5;  bin_map[45]=6'd6;  bin_map[46]=6'd7;  bin_map[47]=6'd8;
    bin_map[48]=6'd9;  bin_map[49]=6'd10; bin_map[50]=6'd11; bin_map[51]=6'd12;
    bin_map[52]=6'd13; bin_map[53]=6'd14; bin_map[54]=6'd15; bin_map[55]=6'd16;
    bin_map[56]=6'd17; bin_map[57]=6'd48; bin_map[58]=6'd18; bin_map[59]=6'd19;
    bin_map[60]=6'd20; bin_map[61]=6'd21; bin_map[62]=6'd22; bin_map[63]=6'd23;
  end

  reg [5:0] bin_index;
  reg [7:0] startup_count;
  reg       active;
  // Latches completion of the current enable period.  The frame
  // sequencer deliberately keeps enable asserted while the IFFT/CP
  // pipeline drains, so active alone is not sufficient to make this a
  // one-shot source: without this latch the module would restart one
  // clock after bin 63.  Re-arm only after enable is deasserted.
  reg       done;

  wire transfer = m_axis_data_tvalid && m_axis_data_tready;

  wire [5:0] route    = bin_map[bin_index];
  wire       is_data  = (route < 6'd48);
  wire       is_pilot_pos = (route == 6'd48);
  wire       is_pilot_neg = (route == 6'd49);

  // Only meaningful when is_data; clamp the index otherwise so the
  // part-select below never depends on an out-of-range route value.
  wire [5:0] sym_idx  = is_data ? route : 6'd0;
  wire real_bit = payload_bits[95 - 2*sym_idx];
  wire imag_bit = payload_bits[94 - 2*sym_idx];

  // QPSK: bit=0 -> +0.7071 (0x5a82), bit=1 -> -0.7071 (0xa57e), Q1.15.
  wire [15:0] data_real = real_bit ? 16'ha57e : 16'h5a82;
  wire [15:0] data_imag = imag_bit ? 16'ha57e : 16'h5a82;

  wire [31:0] bin_value =
      is_data      ? {data_imag, data_real} :
      is_pilot_pos ? 32'h0000_7fff :
      is_pilot_neg ? 32'h0000_8000 :
                      32'h0000_0000;

  assign m_axis_data_tvalid = active;
  assign m_axis_data_tlast  = active && (bin_index == NFFT-1);
  assign m_axis_data_tdata  = bin_value;

  always @(posedge aclk) begin
    if (!aresetn || !enable) begin
      bin_index     <= 6'd0;
      startup_count <= 8'd0;
      active        <= 1'b0;
      done          <= 1'b0;
    end else if (!active && !done) begin
      if (startup_count == STARTUP_CYCLES - 1) begin
        active    <= 1'b1;
        bin_index <= 6'd0;
      end else begin
        startup_count <= startup_count + 1'b1;
      end
    end else if (transfer) begin
      if (bin_index == NFFT - 1) begin
        // One-shot: stop after exactly one frame instead of looping back
        // to bin 0 and continuing -- see training_symbol_source.v for why
        // (the frame sequencer holds `enable` high far longer than NFFT
        // cycles, so a free-running source sends unwanted extra frames
        // before the sequencer ever reacts).
        bin_index <= 6'd0;
        active    <= 1'b0;
        done      <= 1'b1;
      end else begin
        bin_index <= bin_index + 1'b1;
      end
    end
  end

endmodule

`default_nettype wire
