`timescale 1ns/1ps
`default_nettype none

// Plain combinational 2-to-1 AXI-Stream mux: exactly one of the two slave
// inputs is ever "live" at a time (sel picks which), the other's tready is
// simply held low (it should be parked/disabled upstream anyway via its
// own enable input, so it has nothing to send).
//
// The mux logic itself needs no clock (it's just wires + a select), but
// Vivado's IP Integrator still requires every AXI-Stream interface to be
// associated with a clock pin for its own clock/reset propagation to work
// (skipping this made ila_ifft's auto clock-propagation script error out
// at Validate Design). aclk is declared purely to satisfy that and is not
// used by any logic below.
module axis_mux2 (
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME ACLK, ASSOCIATED_BUSIF s_axis_a:s_axis_b:m_axis" *)
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 ACLK CLK" *)
  input  wire        aclk,

  input  wire        sel,   // 0 = pass through A, 1 = pass through B

  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_axis_a, TDATA_NUM_BYTES 4, HAS_TREADY 1, HAS_TLAST 1" *)
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_a TDATA" *)
  input  wire [31:0] s_axis_a_tdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_a TVALID" *)
  input  wire        s_axis_a_tvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_a TLAST" *)
  input  wire        s_axis_a_tlast,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_a TREADY" *)
  output wire        s_axis_a_tready,

  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_axis_b, TDATA_NUM_BYTES 4, HAS_TREADY 1, HAS_TLAST 1" *)
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_b TDATA" *)
  input  wire [31:0] s_axis_b_tdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_b TVALID" *)
  input  wire        s_axis_b_tvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_b TLAST" *)
  input  wire        s_axis_b_tlast,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_b TREADY" *)
  output wire        s_axis_b_tready,

  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m_axis, TDATA_NUM_BYTES 4, HAS_TREADY 1, HAS_TLAST 1" *)
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TDATA" *)
  output wire [31:0] m_axis_tdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TVALID" *)
  output wire        m_axis_tvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TLAST" *)
  output wire        m_axis_tlast,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TREADY" *)
  input  wire        m_axis_tready
);

  assign m_axis_tdata    = sel ? s_axis_b_tdata  : s_axis_a_tdata;
  assign m_axis_tvalid   = sel ? s_axis_b_tvalid : s_axis_a_tvalid;
  assign m_axis_tlast    = sel ? s_axis_b_tlast  : s_axis_a_tlast;
  assign s_axis_a_tready = !sel && m_axis_tready;
  assign s_axis_b_tready =  sel && m_axis_tready;

  wire _unused_ok = &{1'b0, aclk};

endmodule

`default_nettype wire
