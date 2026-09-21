`timescale 1ns/1ps

module fft_config_tb;
  reg clk = 1'b0;
  reg resetn = 1'b0;
  reg ready = 1'b0;
  wire [7:0] data;
  wire valid;

  always #5 clk = ~clk;

  fft_config dut (
    .aclk(clk),
    .aresetn(resetn),
    .m_axis_config_tdata(data),
    .m_axis_config_tvalid(valid),
    .m_axis_config_tready(ready)
  );

  initial begin
    repeat (3) @(negedge clk);
    resetn = 1'b1;

    repeat (3) begin
      @(negedge clk);
      if (!valid || data !== 8'h54)
        $fatal(1, "Configuration was not held while TREADY was low");
    end

    ready = 1'b1;
    @(negedge clk);
    ready = 1'b0;
    @(negedge clk);
    if (valid)
      $fatal(1, "TVALID did not clear after handshake");

    repeat (3) @(negedge clk);
    if (valid)
      $fatal(1, "Configuration was sent more than once");

    $display("PASS fft_config one-shot AXI-Stream handshake");
    $finish;
  end

  initial begin
    #1000;
    $fatal(1, "Timeout");
  end
endmodule
