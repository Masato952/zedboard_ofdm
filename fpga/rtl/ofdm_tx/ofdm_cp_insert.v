`timescale 1ns/1ps
`default_nettype none

// Stage 2 of the TX-IFFT-to-PL migration (see python/README.md roadmap):
// takes xfft_0's raw 64-point IFFT output and prepends a cyclic prefix,
// matching ofdm/core.py's add_cp():
//     symbol = concatenate([t[nfft-cp_len:], t])   # CP (16) + Body (64) = 80
//
// The CP is the LAST cp_len samples of the block, which only fully arrive
// once the whole 64-point block has streamed in (t63 is the very last
// sample) -- so this module must buffer the entire block before it can
// start emitting anything (CP has to go out first). It uses a single
// 64-entry buffer and simply stalls new input (s_axis_data_tready = 0)
// while draining the previous block's 80-sample output; that is fine for
// this bring-up/verification stage but is a throughput limit worth
// revisiting (double-buffering) once this feeds a real back-to-back frame
// sequencer (Stage 3).
module ofdm_cp_insert #(
  parameter integer NFFT   = 64,
  parameter integer CP_LEN = 16
) (
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME ACLK, ASSOCIATED_BUSIF S_AXIS_DATA:M_AXIS_DATA, ASSOCIATED_RESET ARESETN" *)
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 ACLK CLK" *)
  input  wire        aclk,

  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME ARESETN, POLARITY ACTIVE_LOW" *)
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 ARESETN RST" *)
  input  wire        aresetn,

  // slave: raw NFFT-point IFFT output from xfft_0
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXIS_DATA, TDATA_NUM_BYTES 4, HAS_TREADY 1, HAS_TLAST 1" *)
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_DATA TDATA" *)
  input  wire [31:0] s_axis_data_tdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_DATA TVALID" *)
  input  wire        s_axis_data_tvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_DATA TREADY" *)
  output wire        s_axis_data_tready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_DATA TLAST" *)
  input  wire        s_axis_data_tlast,

  // master: CP(16) + Body(64) = 80 points per symbol
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

  localparam integer SYM_LEN = NFFT + CP_LEN; // 80

  (* ram_style = "distributed" *)
  reg [31:0] buf_mem [0:NFFT-1];

  reg [5:0] wr_addr;
  reg       reading;      // 1 while draining the CP+body output
  reg [6:0] rd_count;     // 0..SYM_LEN-1 (0..79)

  wire wr_transfer = s_axis_data_tvalid && s_axis_data_tready;
  wire rd_transfer = m_axis_data_tvalid && m_axis_data_tready;

  // Only accept new IFFT samples while not busy draining the previous
  // symbol -- keeps the single buffer from being overwritten mid-read.
  assign s_axis_data_tready = !reading;

  always @(posedge aclk) begin
    if (!aresetn) begin
      wr_addr <= 6'd0;
    end else if (wr_transfer) begin
      buf_mem[wr_addr] <= s_axis_data_tdata;
      wr_addr <= wr_addr + 1'b1;
    end
  end

  always @(posedge aclk) begin
    if (!aresetn) begin
      reading  <= 1'b0;
      rd_count <= 7'd0;
    end else if (!reading) begin
      // Block complete once bin NFFT-1 has been written (tlast on input).
      if (wr_transfer && s_axis_data_tlast) begin
        reading  <= 1'b1;
        rd_count <= 7'd0;
      end
    end else if (rd_transfer) begin
      if (rd_count == SYM_LEN - 1) begin
        reading  <= 1'b0;
        rd_count <= 7'd0;
      end else begin
        rd_count <= rd_count + 1'b1;
      end
    end
  end

  // rd_count 0..CP_LEN-1      -> CP,   read buf_mem[NFFT-CP_LEN + rd_count]
  // rd_count CP_LEN..SYM_LEN-1 -> Body, read buf_mem[rd_count - CP_LEN]
  wire [5:0] rd_addr = (rd_count < CP_LEN)
                        ? (NFFT - CP_LEN) + rd_count[5:0]
                        : rd_count[5:0] - CP_LEN[5:0];

  assign m_axis_data_tvalid = reading;
  assign m_axis_data_tdata  = buf_mem[rd_addr];
  assign m_axis_data_tlast  = reading && (rd_count == SYM_LEN - 1);

endmodule

`default_nettype wire
