`timescale 1ns/1ps
`default_nettype none

// Final stage of the TX-IFFT-to-PL migration (see python/README.md
// roadmap): the state machine that ties everything else together into one
// complete frame -- Training#1 + Training#2 + Payload#0..#(N-1), matching
// ofdm/core.py's build_frame() layout, where N = SYMBOL_COUNT from
// ofdm_frame_regs.v.
//
// One "current_symbol" counter walks the whole frame: symbols 0 and 1 are
// training (identical content both times -- training_symbol_source.v is
// simply re-run twice), symbols 2..2+N-1 are payload, with symbol_index
// fed to ofdm_frame_regs.v = current_symbol-2.
//
// Each symbol goes through PARK (both sources' enable held low so they
// reset cleanly and symbol_index is safe to change) then RUN (the
// selected source enabled, mux'd into xfft_0 via axis_mux2.v) until
// ofdm_cp_insert_0's own output finishes that symbol's 80-sample CP+Body
// (its tlast transfer) -- only then does the sequencer move on, so there
// is never more than one symbol in flight through xfft_0/ofdm_cp_insert_0
// at a time. After the last payload symbol the whole frame repeats from
// Training#1 (free-running, matching every other bring-up source module
// in this project so it can be exercised continuously with the ILA).
module ofdm_frame_sequencer #(
  parameter integer PARK_CYCLES = 4
) (
  input  wire        aclk,
  input  wire        aresetn,

  // From ofdm_frame_regs.v.
  input  wire [4:0]  symbol_count,
  // To ofdm_frame_regs.v: which payload symbol to present right now.
  output reg  [3:0]  symbol_index,

  // To training_symbol_source.v / qpsk_subcarrier_mapper.v.
  output reg         train_enable,
  output reg         payload_enable,

  // Observed from ofdm_cp_insert_0's M_AXIS_DATA: marks the last beat of
  // the current symbol's 80-sample CP+Body actually leaving the pipeline.
  input  wire        cp_tvalid,
  input  wire        cp_tready,
  input  wire        cp_tlast
);

  localparam PARK = 1'b0;
  localparam RUN  = 1'b1;

  reg        state;
  reg [7:0]  park_count;
  reg [4:0]  current_symbol;

  wire [4:0] total_symbols   = symbol_count + 5'd2;
  wire       is_training     = (current_symbol < 5'd2);
  wire [4:0] payload_idx_full = current_symbol - 5'd2;

  wire cp_symbol_done = cp_tvalid && cp_tready && cp_tlast;

  always @(posedge aclk) begin
    if (!aresetn) begin
      state          <= PARK;
      park_count     <= 8'd0;
      current_symbol <= 5'd0;
      train_enable   <= 1'b0;
      payload_enable <= 1'b0;
      symbol_index   <= 4'd0;
    end else begin
      case (state)
        PARK: begin
          train_enable   <= 1'b0;
          payload_enable <= 1'b0;
          symbol_index   <= payload_idx_full[3:0];
          if (park_count == PARK_CYCLES - 1) begin
            park_count     <= 8'd0;
            train_enable   <= is_training;
            payload_enable <= !is_training;
            state          <= RUN;
          end else begin
            park_count <= park_count + 1'b1;
          end
        end

        RUN: begin
          if (cp_symbol_done) begin
            train_enable   <= 1'b0;
            payload_enable <= 1'b0;
            state          <= PARK;
            if (current_symbol + 1'b1 == total_symbols)
              current_symbol <= 5'd0;
            else
              current_symbol <= current_symbol + 1'b1;
          end
        end

        default: state <= PARK;
      endcase
    end
  end

endmodule

`default_nettype wire
