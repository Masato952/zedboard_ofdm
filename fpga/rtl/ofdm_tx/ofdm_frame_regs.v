`timescale 1ns/1ps
`default_nettype none

// Stage 5 of the TX-IFFT-to-PL migration (see python/README.md roadmap):
// replaces ofdm_payload_regs.v's single 96-bit slot with a buffer for up
// to MAX_SYMBOLS payload symbols, plus a SYMBOL_COUNT register so software
// tells hardware how many of them are actually part of this frame --
// mirrors build_frame()'s n_payload_symbols in ofdm/core.py, just computed
// in Python and handed over as a number instead of recomputed in RTL.
//
// Register map (word offsets, all 32-bit, byte address = offset*4):
//   0x00..0xBC  PAYLOAD_MEM[0..47]   symbol i occupies words 3i,3i+1,3i+2
//                                     = payload_bits[95:64],[63:32],[31:0]
//                                     for that symbol (RW)
//   0xC0        SYMBOL_COUNT         number of valid payload symbols this
//                                     frame (0..MAX_SYMBOLS), low 5 bits (RW)
//
// Writes/reads to any other offset complete with DECERR. Same accepted
// bring-up limitation as ofdm_payload_regs.v: no latching/double-buffering,
// so writing mid-frame can tear a transmission in flight.
module ofdm_frame_regs #(
  parameter integer MAX_SYMBOLS        = 16,
  parameter integer C_S_AXI_ADDR_WIDTH = 8,
  parameter integer C_S_AXI_DATA_WIDTH = 32
) (
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXI_ACLK, ASSOCIATED_BUSIF S_AXI, ASSOCIATED_RESET S_AXI_ARESETN" *)
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 S_AXI_ACLK CLK" *)
  input  wire                              s_axi_aclk,
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXI_ARESETN, POLARITY ACTIVE_LOW" *)
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 S_AXI_ARESETN RST" *)
  input  wire                              s_axi_aresetn,

  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXI, PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 8" *)
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWADDR" *)
  input  wire [C_S_AXI_ADDR_WIDTH-1:0]     s_axi_awaddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWPROT" *)
  input  wire [2:0]                        s_axi_awprot,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWVALID" *)
  input  wire                              s_axi_awvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWREADY" *)
  output wire                              s_axi_awready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WDATA" *)
  input  wire [C_S_AXI_DATA_WIDTH-1:0]     s_axi_wdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WSTRB" *)
  input  wire [(C_S_AXI_DATA_WIDTH/8)-1:0] s_axi_wstrb,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WVALID" *)
  input  wire                              s_axi_wvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WREADY" *)
  output wire                              s_axi_wready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BRESP" *)
  output reg  [1:0]                        s_axi_bresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BVALID" *)
  output reg                               s_axi_bvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BREADY" *)
  input  wire                              s_axi_bready,

  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARADDR" *)
  input  wire [C_S_AXI_ADDR_WIDTH-1:0]     s_axi_araddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARPROT" *)
  input  wire [2:0]                        s_axi_arprot,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARVALID" *)
  input  wire                              s_axi_arvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARREADY" *)
  output wire                              s_axi_arready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RDATA" *)
  output reg  [C_S_AXI_DATA_WIDTH-1:0]     s_axi_rdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RRESP" *)
  output reg  [1:0]                        s_axi_rresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RVALID" *)
  output reg                               s_axi_rvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RREADY" *)
  input  wire                              s_axi_rready,

  // Which payload symbol to present on payload_bits right now -- driven by
  // ofdm_frame_sequencer.v.
  input  wire [3:0]                        symbol_index,
  // 96 raw bits of that symbol, for qpsk_subcarrier_mapper.v.
  output wire [95:0]                       payload_bits,
  // Number of valid payload symbols in this frame, for the sequencer.
  output wire [4:0]                        symbol_count
);

  localparam integer MEM_WORDS  = MAX_SYMBOLS * 3;
  localparam integer COUNT_WORD = MEM_WORDS; // one word right after the memory

  reg [31:0] mem [0:MEM_WORDS-1];
  reg [4:0]  symbol_count_reg;

  assign payload_bits = {mem[symbol_index*3], mem[symbol_index*3+1], mem[symbol_index*3+2]};
  assign symbol_count = symbol_count_reg;

  reg aw_received;
  reg w_received;
  reg [C_S_AXI_ADDR_WIDTH-1:0] aw_addr_latched;

  wire aw_handshake = s_axi_awvalid && s_axi_awready;
  wire w_handshake  = s_axi_wvalid  && s_axi_wready;
  wire ar_handshake = s_axi_arvalid && s_axi_arready;

  wire [C_S_AXI_ADDR_WIDTH-1:0] write_addr =
      aw_handshake ? s_axi_awaddr : aw_addr_latched;

  assign s_axi_awready = !aw_received && !s_axi_bvalid;
  assign s_axi_wready  = !w_received  && !s_axi_bvalid;

  function address_is_valid;
    input [C_S_AXI_ADDR_WIDTH-1:0] address;
    begin
      address_is_valid = (address[C_S_AXI_ADDR_WIDTH-1:2] <= COUNT_WORD[C_S_AXI_ADDR_WIDTH-3:0]);
    end
  endfunction

  integer i;

  always @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
      aw_received      <= 1'b0;
      w_received       <= 1'b0;
      aw_addr_latched  <= {C_S_AXI_ADDR_WIDTH{1'b0}};
      s_axi_bresp      <= 2'b00;
      s_axi_bvalid     <= 1'b0;
      symbol_count_reg <= 5'd0;
      for (i = 0; i < MEM_WORDS; i = i + 1)
        mem[i] <= 32'd0;
    end else begin
      if (aw_handshake) begin
        aw_received     <= 1'b1;
        aw_addr_latched <= s_axi_awaddr;
      end
      if (w_handshake)
        w_received <= 1'b1;

      if (!s_axi_bvalid &&
          (aw_received || aw_handshake) &&
          (w_received  || w_handshake)) begin
        aw_received <= 1'b0;
        w_received  <= 1'b0;
        s_axi_bvalid <= 1'b1;
        // Use this cycle's fresh awaddr when address+data arrive together
        // instead of aw_addr_latched, which a same-cycle non-blocking
        // assignment above hasn't updated yet (see ofdm_payload_regs.v).
        s_axi_bresp <= address_is_valid(write_addr) ? 2'b00 : 2'b11;
        if (address_is_valid(write_addr)) begin
          if (write_addr[C_S_AXI_ADDR_WIDTH-1:2] == COUNT_WORD[C_S_AXI_ADDR_WIDTH-3:0])
            symbol_count_reg <= s_axi_wdata[4:0];
          else
            mem[write_addr[C_S_AXI_ADDR_WIDTH-1:2]] <= s_axi_wdata;
        end
      end else if (s_axi_bvalid && s_axi_bready) begin
        s_axi_bvalid <= 1'b0;
      end
    end
  end

  reg [31:0] read_data;
  always @(*) begin
    if (s_axi_araddr[C_S_AXI_ADDR_WIDTH-1:2] == COUNT_WORD[C_S_AXI_ADDR_WIDTH-3:0])
      read_data = {27'd0, symbol_count_reg};
    else
      read_data = mem[s_axi_araddr[C_S_AXI_ADDR_WIDTH-1:2]];
  end

  assign s_axi_arready = !s_axi_rvalid;

  always @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
      s_axi_rdata  <= {C_S_AXI_DATA_WIDTH{1'b0}};
      s_axi_rresp  <= 2'b00;
      s_axi_rvalid <= 1'b0;
    end else begin
      if (ar_handshake) begin
        s_axi_rdata  <= address_is_valid(s_axi_araddr) ? read_data : 32'd0;
        s_axi_rresp  <= address_is_valid(s_axi_araddr) ? 2'b00 : 2'b11;
        s_axi_rvalid <= 1'b1;
      end else if (s_axi_rvalid && s_axi_rready) begin
        s_axi_rvalid <= 1'b0;
      end
    end
  end

  wire _unused_ok = &{1'b0, s_axi_awprot, s_axi_wstrb, s_axi_arprot};

endmodule

`default_nettype wire
