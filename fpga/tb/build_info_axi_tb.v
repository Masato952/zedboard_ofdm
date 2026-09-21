`timescale 1ns/1ps

`include "build_info_regs.vh"

module build_info_axi_tb;
  reg clk = 1'b0;
  reg resetn = 1'b0;
  always #5 clk = ~clk;

  reg  [4:0]  awaddr = 5'd0;
  reg  [2:0]  awprot = 3'd0;
  reg         awvalid = 1'b0;
  wire        awready;
  reg  [31:0] wdata = 32'd0;
  reg  [3:0]  wstrb = 4'd0;
  reg         wvalid = 1'b0;
  wire        wready;
  wire [1:0]  bresp;
  wire        bvalid;
  reg         bready = 1'b0;
  reg  [4:0]  araddr = 5'd0;
  reg  [2:0]  arprot = 3'd0;
  reg         arvalid = 1'b0;
  wire        arready;
  wire [31:0] rdata;
  wire [1:0]  rresp;
  wire        rvalid;
  reg         rready = 1'b0;

  build_info_axi dut (
    .s_axi_aclk(clk), .s_axi_aresetn(resetn),
    .s_axi_awaddr(awaddr), .s_axi_awprot(awprot),
    .s_axi_awvalid(awvalid), .s_axi_awready(awready),
    .s_axi_wdata(wdata), .s_axi_wstrb(wstrb),
    .s_axi_wvalid(wvalid), .s_axi_wready(wready),
    .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
    .s_axi_araddr(araddr), .s_axi_arprot(arprot),
    .s_axi_arvalid(arvalid), .s_axi_arready(arready),
    .s_axi_rdata(rdata), .s_axi_rresp(rresp),
    .s_axi_rvalid(rvalid), .s_axi_rready(rready)
  );

  task check_read;
    input [4:0] address;
    input [31:0] expected_data;
    input [1:0] expected_resp;
    begin
      @(negedge clk);
      araddr = address;
      arvalid = 1'b1;
      while (!arready) @(negedge clk);
      @(negedge clk);
      arvalid = 1'b0;
      rready = 1'b1;
      while (!rvalid) @(negedge clk);
      if (rdata !== expected_data || rresp !== expected_resp) begin
        $display("FAIL read addr=%02x data=%08x resp=%x expected=%08x/%x",
                 address, rdata, rresp, expected_data, expected_resp);
        $fatal(1);
      end
      @(negedge clk);
      rready = 1'b0;
    end
  endtask

  initial begin
    repeat (4) @(negedge clk);
    resetn = 1'b1;

    check_read(5'h00, `BUILD_INFO_MAGIC,           2'b00);
    check_read(5'h04, `BUILD_INFO_PROJECT_VERSION, 2'b00);
    check_read(5'h08, `BUILD_INFO_GIT_HASH,        2'b00);
    check_read(5'h0c, `BUILD_INFO_BUILD_DATE,      2'b00);
    check_read(5'h10, `BUILD_INFO_BUILD_TIME,      2'b00);
    check_read(5'h14, `BUILD_INFO_DIRTY_FLAG,      2'b00);
    check_read(5'h1c, 32'd0,                       2'b11);

    // Present AW and W in different cycles to verify independent channels.
    @(negedge clk);
    awaddr = 5'h00;
    awvalid = 1'b1;
    while (!awready) @(negedge clk);
    @(negedge clk);
    awvalid = 1'b0;
    repeat (2) @(negedge clk);
    wdata = 32'hDEADBEEF;
    wstrb = 4'hf;
    wvalid = 1'b1;
    while (!wready) @(negedge clk);
    @(negedge clk);
    wvalid = 1'b0;
    bready = 1'b1;
    while (!bvalid) @(negedge clk);
    if (bresp !== 2'b10) begin
      $display("FAIL write response=%x expected=2", bresp);
      $fatal(1);
    end
    @(negedge clk);
    bready = 1'b0;

    $display("PASS build_info_axi register and AXI-Lite tests");
    $finish;
  end

  initial begin
    #10000;
    $fatal(1, "Timeout");
  end
endmodule
