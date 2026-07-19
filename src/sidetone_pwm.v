/*
 * Copyright (c) 2026 Vladimir Velikanov
 * SPDX-License-Identifier: Apache-2.0
 *
 * Audio: sidetone generator. A square wave at the selected pitch, gated by
 * key, encoded as 5-bit PWM at f_clk / 32 (~312 kHz @ 10 MHz) for the TT
 * Audio Pmod. The carrier never stops; silence is 50% duty (mid-rail after
 * the Pmod's filter). Key gating is applied at tone zero crossings to
 * suppress clicks; audio_en mutes immediately.
 */

`default_nettype none

module sidetone_pwm (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       key,
    input  wire       audio_en,
    input  wire [1:0] tone_sel,
    output wire       audio_pwm
);

  reg [13:0] tone_cnt;
  reg [13:0] half_period;
  reg        tone;
  reg        gate;
  reg [ 4:0] pwm_cnt;
  reg [ 4:0] duty;

  always @(*) begin
    case (tone_sel)
      2'b00:   half_period = 14'd8333;   // ~600 Hz @ 10 MHz
      2'b01:   half_period = 14'd6250;   // ~800 Hz
      2'b10:   half_period = 14'd5000;   // ~1000 Hz
      default: half_period = 14'd11364;  // ~440 Hz
    endcase
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tone_cnt <= 14'd0;
      tone     <= 1'b0;
      gate     <= 1'b0;
      pwm_cnt  <= 5'd0;
    end else begin
      if (tone_cnt >= half_period - 14'd1) begin
        tone_cnt <= 14'd0;
        tone     <= ~tone;
        gate     <= key;  // zero-crossing aligned keying
      end else begin
        tone_cnt <= tone_cnt + 14'd1;
      end
      if (!audio_en) gate <= 1'b0;  // immediate mute
      pwm_cnt <= pwm_cnt + 5'd1;
    end
  end

  always @(*) begin
    if (!gate) duty = 5'd16;       // idle: 50% duty, filter output at mid-rail
    else if (tone) duty = 5'd30;
    else duty = 5'd2;
  end

  assign audio_pwm = (pwm_cnt < duty);

endmodule
