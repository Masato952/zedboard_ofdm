`timescale 1ns/1ps
`default_nettype none

`include "build_info_regs.vh"

// Read-only build identification block.
//
// Register map:
//   0x00 MAGIC            ASCII "OFDM"
//   0x04 PROJECT_VERSION  {major[7:0], minor[7:0], patch[15:0]}
//   0x08 GIT_HASH         first 32 bits of the Git commit hash
//   0x0c BUILD_DATE       decimal YYYYMMDD
//   0x10 BUILD_TIME       decimal HHMMSS
//   0x14 DIRTY_FLAG       0 = clean, 1 = uncommitted changes
//
// All writes complete with SLVERR. Reads from undefined offsets complete with
// DECERR and return zero.
module build_info_axi #(
  parameter integer C_S_AXI_ADDR_WIDTH = 5,
  parameter integer C_S_AXI_DATA_WIDTH = 32,
  parameter [31:0]  P_MAGIC             = `BUILD_INFO_MAGIC,
  parameter [31:0]  P_PROJECT_VERSION   = `BUILD_INFO_PROJECT_VERSION,
  parameter [31:0]  P_GIT_HASH          = `BUILD_INFO_GIT_HASH,
  parameter [31:0]  P_BUILD_DATE        = `BUILD_INFO_BUILD_DATE,
  parameter [31:0]  P_BUILD_TIME        = `BUILD_INFO_BUILD_TIME,
  parameter [31:0]  P_DIRTY_FLAG        = `BUILD_INFO_DIRTY_FLAG
) (
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXI_ACLK, ASSOCIATED_BUSIF S_AXI, ASSOCIATED_RESET S_AXI_ARESETN" *)
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 S_AXI_ACLK CLK" *)
  input  wire                            s_axi_aclk,
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXI_ARESETN, POLARITY ACTIVE_LOW" *)
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 S_AXI_ARESETN RST" *)
  input  wire                            s_axi_aresetn,

  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXI, PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 5" *)
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWADDR" *)
  input  wire [C_S_AXI_ADDR_WIDTH-1:0]   s_axi_awaddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWPROT" *)
  input  wire [2:0]                      s_axi_awprot,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWVALID" *)
  input  wire                            s_axi_awvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWREADY" *)
  output wire                            s_axi_awready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WDATA" *)
  input  wire [C_S_AXI_DATA_WIDTH-1:0]   s_axi_wdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WSTRB" *)
  input  wire [(C_S_AXI_DATA_WIDTH/8)-1:0] s_axi_wstrb,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WVALID" *)
  input  wire                            s_axi_wvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WREADY" *)
  output wire                            s_axi_wready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BRESP" *)
  output reg  [1:0]                      s_axi_bresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BVALID" *)
  output reg                             s_axi_bvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BREADY" *)
  input  wire                            s_axi_bready,

  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARADDR" *)
  input  wire [C_S_AXI_ADDR_WIDTH-1:0]   s_axi_araddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARPROT" *)
  input  wire [2:0]                      s_axi_arprot,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARVALID" *)
  input  wire                            s_axi_arvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARREADY" *)
  output wire                            s_axi_arready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RDATA" *)
  output reg  [C_S_AXI_DATA_WIDTH-1:0]   s_axi_rdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RRESP" *)
  output reg  [1:0]                      s_axi_rresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RVALID" *)
  output reg                             s_axi_rvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RREADY" *)
  input  wire                            s_axi_rready
);

  localparam [1:0] AXI_RESP_OKAY   = 2'b00;
  localparam [1:0] AXI_RESP_SLVERR = 2'b10;
  localparam [1:0] AXI_RESP_DECERR = 2'b11;

  reg aw_received;
  reg w_received;

  wire aw_handshake = s_axi_awvalid && s_axi_awready;
  wire w_handshake  = s_axi_wvalid  && s_axi_wready;
  wire ar_handshake = s_axi_arvalid && s_axi_arready;

  // Address and data may arrive independently on AXI-Lite, so remember each
  // channel until both halves of the rejected write have been received.
  assign s_axi_awready = !aw_received && !s_axi_bvalid;
  assign s_axi_wready  = !w_received  && !s_axi_bvalid;

  always @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
      aw_received <= 1'b0;
      w_received  <= 1'b0;
      s_axi_bresp <= AXI_RESP_OKAY;
      s_axi_bvalid <= 1'b0;
    end else begin
      if (aw_handshake)
        aw_received <= 1'b1;
      if (w_handshake)
        w_received <= 1'b1;

      if (!s_axi_bvalid &&
          (aw_received || aw_handshake) &&
          (w_received  || w_handshake)) begin
        aw_received <= 1'b0;
        w_received  <= 1'b0;
        s_axi_bresp <= AXI_RESP_SLVERR;
        s_axi_bvalid <= 1'b1;
      end else if (s_axi_bvalid && s_axi_bready) begin
        s_axi_bvalid <= 1'b0;
      end
    end
  end

  function [31:0] read_register;
    input [C_S_AXI_ADDR_WIDTH-1:0] address;
    begin
      case (address[C_S_AXI_ADDR_WIDTH-1:2])
        3'd0: read_register = P_MAGIC;
        3'd1: read_register = P_PROJECT_VERSION;
        3'd2: read_register = P_GIT_HASH;
        3'd3: read_register = P_BUILD_DATE;
        3'd4: read_register = P_BUILD_TIME;
        3'd5: read_register = P_DIRTY_FLAG;
        default: read_register = 32'd0;
      endcase
    end
  endfunction

  function address_is_valid;
    input [C_S_AXI_ADDR_WIDTH-1:0] address;
    begin
      address_is_valid = (address[C_S_AXI_ADDR_WIDTH-1:2] <= 3'd5);
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

  // Explicitly mark intentionally unused write/protection inputs.
  wire _unused_ok = &{1'b0, s_axi_awaddr, s_axi_awprot, s_axi_wdata,
                      s_axi_wstrb, s_axi_arprot};

endmodule

`default_nettype wire
