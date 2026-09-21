`timescale 1ns/1ps

module ifft_test_source_tb;
  reg clk = 1'b0;
  reg resetn = 1'b0;
  reg ready = 1'b0;
  wire [31:0] data;
  wire valid;
  wire last;
  integer accepted = 0;

  always #5 clk = ~clk;

  ifft_test_source #(.STARTUP_CYCLES(4)) dut (
    .aclk(clk),
    .aresetn(resetn),
    .m_axis_data_tdata(data),
    .m_axis_data_tvalid(valid),
    .m_axis_data_tready(ready),
    .m_axis_data_tlast(last)
  );

  always @(posedge clk) begin
    if (valid && ready) begin
      if ((accepted % 64) == 1) begin
        if (data !== 32'h00004000)
          $fatal(1, "Bin 1 has incorrect data: %08x", data);
      end else if (data !== 32'h00000000) begin
        $fatal(1, "Unexpected non-zero bin %0d: %08x", accepted % 64, data);
      end

      if (last !== ((accepted % 64) == 63))
        $fatal(1, "TLAST error at bin %0d", accepted % 64);

      accepted = accepted + 1;
      if (accepted == 128) begin
        $display("PASS ifft_test_source two frames with backpressure");
        $finish;
      end
    end
  end

  initial begin
    repeat (3) @(negedge clk);
    resetn = 1'b1;
    repeat (8) @(negedge clk);
    ready = 1'b1;
    repeat (20) @(negedge clk);
    ready = 1'b0;
    repeat (5) @(negedge clk);
    ready = 1'b1;
  end

  initial begin
    #5000;
    $fatal(1, "Timeout");
  end
endmodule
