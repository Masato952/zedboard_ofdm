`timescale 1ns/1ps
`default_nettype none

// Training-symbol frequency source: the fixed 64-point BPSK spectrum
// ofdm/core.py's make_training_frequency() generates from the deterministic
// seed 0x9361 (all 52 used subcarriers = +-1, no pilot/data split; the
// other 12 bins are the DC + guard-band zeros, same as everywhere else in
// this project). TX and RX each derive this same pattern independently, so
// unlike PAYLOAD_BITS this is never something software needs to change --
// hardcoded ROM is the right, permanent home for it, not just a bring-up
// stand-in.
//
// Feed this module's output into xfft_0 in place of
// qpsk_subcarrier_mapper_0 to produce one training symbol (CP16+64=80
// samples) out of ofdm_cp_insert_0; a full preamble is this same 80-sample
// symbol sent twice back-to-back (Training #1 == Training #2), which the
// frame sequencer (next stage) is what actually re-triggers this module a
// second time -- this module itself only ever produces one symbol's worth
// per run, same shape as ifft_payload0_test_source.v /
// qpsk_subcarrier_mapper.v.
module training_symbol_source #(
  parameter integer NFFT           = 64,
  parameter integer STARTUP_CYCLES = 16
) (
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME ACLK, ASSOCIATED_BUSIF M_AXIS_DATA, ASSOCIATED_RESET ARESETN" *)
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 ACLK CLK" *)
  input  wire        aclk,

  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME ARESETN, POLARITY ACTIVE_LOW" *)
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 ARESETN RST" *)
  input  wire        aresetn,

  // Gates this module on/off for the frame sequencer (Stage 5): held low,
  // it parks at bin_index=0/inactive and produces nothing, so it can share
  // xfft_0 with qpsk_subcarrier_mapper.v without both running at once.
  // Tied to 1'b1 this behaves exactly as it did in the earlier bring-up
  // verification (byte-for-byte identical ILA capture).
  input  wire        enable,

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

  reg [31:0] rom [0:NFFT-1];
  initial begin
    rom[ 0] = 32'h0000_0000; rom[ 1] = 32'h0000_7fff; rom[ 2] = 32'h0000_8000; rom[ 3] = 32'h0000_8000;
    rom[ 4] = 32'h0000_7fff; rom[ 5] = 32'h0000_8000; rom[ 6] = 32'h0000_8000; rom[ 7] = 32'h0000_8000;
    rom[ 8] = 32'h0000_7fff; rom[ 9] = 32'h0000_7fff; rom[10] = 32'h0000_7fff; rom[11] = 32'h0000_8000;
    rom[12] = 32'h0000_7fff; rom[13] = 32'h0000_7fff; rom[14] = 32'h0000_8000; rom[15] = 32'h0000_8000;
    rom[16] = 32'h0000_7fff; rom[17] = 32'h0000_7fff; rom[18] = 32'h0000_8000; rom[19] = 32'h0000_8000;
    rom[20] = 32'h0000_7fff; rom[21] = 32'h0000_7fff; rom[22] = 32'h0000_8000; rom[23] = 32'h0000_8000;
    rom[24] = 32'h0000_8000; rom[25] = 32'h0000_8000; rom[26] = 32'h0000_7fff; rom[27] = 32'h0000_0000;
    rom[28] = 32'h0000_0000; rom[29] = 32'h0000_0000; rom[30] = 32'h0000_0000; rom[31] = 32'h0000_0000;
    rom[32] = 32'h0000_0000; rom[33] = 32'h0000_0000; rom[34] = 32'h0000_0000; rom[35] = 32'h0000_0000;
    rom[36] = 32'h0000_0000; rom[37] = 32'h0000_0000; rom[38] = 32'h0000_7fff; rom[39] = 32'h0000_7fff;
    rom[40] = 32'h0000_7fff; rom[41] = 32'h0000_7fff; rom[42] = 32'h0000_8000; rom[43] = 32'h0000_8000;
    rom[44] = 32'h0000_7fff; rom[45] = 32'h0000_7fff; rom[46] = 32'h0000_8000; rom[47] = 32'h0000_8000;
    rom[48] = 32'h0000_7fff; rom[49] = 32'h0000_8000; rom[50] = 32'h0000_8000; rom[51] = 32'h0000_8000;
    rom[52] = 32'h0000_8000; rom[53] = 32'h0000_7fff; rom[54] = 32'h0000_8000; rom[55] = 32'h0000_7fff;
    rom[56] = 32'h0000_7fff; rom[57] = 32'h0000_7fff; rom[58] = 32'h0000_8000; rom[59] = 32'h0000_8000;
    rom[60] = 32'h0000_7fff; rom[61] = 32'h0000_7fff; rom[62] = 32'h0000_8000; rom[63] = 32'h0000_7fff;
  end

  reg [5:0] bin_index;
  reg [7:0] startup_count;
  reg       active;
  // Send exactly one training symbol per enable assertion.  The frame
  // sequencer keeps enable high while the downstream IFFT/CP pipeline
  // drains, so wait for enable to go low before re-arming.
  reg       done;

  wire transfer = m_axis_data_tvalid && m_axis_data_tready;

  assign m_axis_data_tvalid = active;
  assign m_axis_data_tlast  = active && (bin_index == NFFT-1);
  assign m_axis_data_tdata  = rom[bin_index];

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
        // to bin 0 and continuing. The frame sequencer holds `enable` high
        // for much longer than NFFT cycles (it waits for the whole
        // xfft_0 + ofdm_cp_insert_0 round trip before dropping it), so a
        // free-running source would send several extra unwanted frames
        // back-to-back before the sequencer ever reacts -- exactly the
        // kind of framing mismatch xfft_0's event_tlast_missing flags.
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
