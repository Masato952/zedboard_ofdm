`timescale 1ns/1ps
`default_nettype none

// Stage 4 of the TX-IFFT-to-PL migration (see python/README.md roadmap):
// a small read/write AXI-Lite register file that lets software (Python via
// pyadi/no-OS memory-mapped access, or ARM/Linux) load the 96 payload bits
// that qpsk_subcarrier_mapper.v maps onto subcarriers, instead of them
// being a fixed localparam baked in at synthesis time.
//
// Register map (word offsets, all 32-bit, byte address = offset*4):
//   0x00 PAYLOAD_BITS_HI   payload_bits[95:64]  (RW)
//   0x04 PAYLOAD_BITS_MID  payload_bits[63:32]  (RW)
//   0x08 PAYLOAD_BITS_LO   payload_bits[31:0]   (RW)
//
// Writes to any other offset, and reads from any other offset, complete
// with DECERR. This intentionally does not latch/double-buffer: software
// writing new bits mid-symbol can tear a transmission. That's an accepted
// bring-up-stage limitation, not yet a real, always-safe control path.
module ofdm_payload_regs #(
  parameter integer C_S_AXI_ADDR_WIDTH = 5,
  parameter integer C_S_AXI_DATA_WIDTH = 32
) (
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXI_ACLK, ASSOCIATED_BUSIF S_AXI, ASSOCIATED_RESET S_AXI_ARESETN" *)
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 S_AXI_ACLK CLK" *)
  input  wire                              s_axi_aclk,
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXI_ARESETN, POLARITY ACTIVE_LOW" *)
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 S_AXI_ARESETN RST" *)
  input  wire                              s_axi_aresetn,

  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXI, PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 5" *)
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

  // Live payload bits, consumed by qpsk_subcarrier_mapper.v.
  output wire [95:0]                       payload_bits
);

  localparam [1:0] AXI_RESP_OKAY   = 2'b00;
  localparam [1:0] AXI_RESP_DECERR = 2'b11;

  reg [31:0] reg_hi, reg_mid, reg_lo;
  assign payload_bits = {reg_hi, reg_mid, reg_lo};

  reg aw_received;
  reg w_received;
  reg [C_S_AXI_ADDR_WIDTH-1:0] aw_addr_latched;

  wire aw_handshake = s_axi_awvalid && s_axi_awready;
  wire w_handshake  = s_axi_wvalid  && s_axi_wready;
  wire ar_handshake = s_axi_arvalid && s_axi_arready;

  // The address to use *this cycle*: fresh s_axi_awaddr if AWVALID is
  // handshaking right now, otherwise whatever was latched on an earlier
  // cycle (address arrived before data).
  wire [C_S_AXI_ADDR_WIDTH-1:0] write_addr =
      aw_handshake ? s_axi_awaddr : aw_addr_latched;

  assign s_axi_awready = !aw_received && !s_axi_bvalid;
  assign s_axi_wready  = !w_received  && !s_axi_bvalid;

  function address_is_valid;
    input [C_S_AXI_ADDR_WIDTH-1:0] address;
    begin
      address_is_valid = (address[C_S_AXI_ADDR_WIDTH-1:2] <= 2'd2);
    end
  endfunction

  always @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
      aw_received     <= 1'b0;
      w_received      <= 1'b0;
      aw_addr_latched <= {C_S_AXI_ADDR_WIDTH{1'b0}};
      s_axi_bresp     <= AXI_RESP_OKAY;
      s_axi_bvalid    <= 1'b0;
      reg_hi  <= 32'd0;
      reg_mid <= 32'd0;
      reg_lo  <= 32'd0;
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
        // (the common case) instead of aw_addr_latched, which a
        // same-cycle non-blocking assignment above hasn't updated yet --
        // reading it here would still see the *previous* transaction's
        // address and misroute this write by one register.
        s_axi_bresp  <= address_is_valid(write_addr)
                        ? AXI_RESP_OKAY : AXI_RESP_DECERR;
        if (address_is_valid(write_addr)) begin
          case (write_addr[C_S_AXI_ADDR_WIDTH-1:2])
            2'd0: reg_hi  <= s_axi_wdata;
            2'd1: reg_mid <= s_axi_wdata;
            2'd2: reg_lo  <= s_axi_wdata;
            default: ;
          endcase
        end
      end else if (s_axi_bvalid && s_axi_bready) begin
        s_axi_bvalid <= 1'b0;
      end
    end
  end

  function [31:0] read_register;
    input [C_S_AXI_ADDR_WIDTH-1:0] address;
    begin
      case (address[C_S_AXI_ADDR_WIDTH-1:2])
        2'd0: read_register = reg_hi;
        2'd1: read_register = reg_mid;
        2'd2: read_register = reg_lo;
        default: read_register = 32'd0;
      endcase
    end
  endfunction

  assign s_axi_arready = !s_axi_rvalid;

  always @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
      s_axi_rdata  <= {C_S_AXI_DATA_WIDTH{1'b0}};
      s_axi_rresp  <= AXI_RESP_OKAY;
      s_axi_rvalid <= 1'b0;
    end else begin
      if (ar_handshake) begin
        s_axi_rdata  <= read_register(s_axi_araddr);
        s_axi_rresp  <= address_is_valid(s_axi_araddr)
                        ? AXI_RESP_OKAY : AXI_RESP_DECERR;
        s_axi_rvalid <= 1'b1;
      end else if (s_axi_rvalid && s_axi_rready) begin
        s_axi_rvalid <= 1'b0;
      end
    end
  end

  wire _unused_ok = &{1'b0, s_axi_awprot, s_axi_wstrb, s_axi_arprot};

endmodule

`default_nettype wire
