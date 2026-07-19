/*
 * Copyright (c) 2026 Vladimir Velikanov
 * SPDX-License-Identifier: Apache-2.0
 *
 * Timing: dit-time divider. tick is a single-clock pulse at each dit
 * boundary. The dit length is 2^N clocks, selected by wpm_sel. A new wpm_sel
 * value is latched only while reload is high (IDLE and character
 * boundaries), so a mid-character speed change cannot produce a malformed
 * element.
 */

`default_nettype none

module dit_timer (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [2:0] wpm_sel,
    input  wire       reload,
    output wire       tick
);

  reg [20:0] cnt;
  reg [ 2:0] wpm_cur;
  reg [20:0] limit;

  always @(*) begin
    case (wpm_cur)
      3'b000:  limit = 21'h1FFFFF;  // 2^21 clocks: ~210 ms @ 10 MHz, ~5.7 WPM
      3'b001:  limit = 21'h0FFFFF;  // 2^20: ~105 ms, ~11.4 WPM
      3'b010:  limit = 21'h07FFFF;  // 2^19: ~52 ms, ~23 WPM
      3'b011:  limit = 21'h03FFFF;  // 2^18: ~26 ms, ~46 WPM
      3'b100:  limit = 21'h00FFFF;  // 2^16: ~6.6 ms
      3'b101:  limit = 21'h000FFF;  // 2^12: ~0.41 ms
      3'b110:  limit = 21'h0000FF;  // 2^8:  ~26 us
      default: limit = 21'h00000F;  // 2^4:  1.6 us (simulation turbo)
    endcase
  end

  assign tick = (cnt == limit);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cnt     <= 21'd0;
      wpm_cur <= 3'b000;
    end else if (reload && (wpm_sel != wpm_cur)) begin
      wpm_cur <= wpm_sel;
      cnt     <= 21'd0;
    end else if (tick) begin
      cnt <= 21'd0;
    end else begin
      cnt <= cnt + 21'd1;
    end
  end

endmodule
