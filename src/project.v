/*
 * Copyright (c) 2026 Vladimir Velikanov
 * SPDX-License-Identifier: Apache-2.0
 *
 * tt_um_morse_converter — ASCII-to-Morse converter for Tiny Tapeout.
 *
 * Accepts 7-bit ASCII characters over a load/ready handshake, looks them up
 * in a combinational ROM, and serializes the ITU-R M.1677-1 element sequence
 * on the key line at a selectable, clock-proportional speed. A PWM sidetone
 * for the TT Audio Pmod is generated on uo[7].
 *
 * Top-level wrapper only: pin mapping, reset synchronization, and the
 * uio_oe tie-off. The functional blocks live in their own files:
 *   morse_rom.v    — character encoding (ASCII -> element pattern)
 *   dit_timer.v    — timing (dit-rate divider, speed selection)
 *   morse_fsm.v    — serialization and the load/ready handshake
 *   sidetone_pwm.v — audio (sidetone + PWM for the TT Audio Pmod)
 */

`default_nettype none

module tt_um_morse_converter (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

  // Reset: asynchronous assert, synchronous release.
  reg [1:0] rst_sync;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) rst_sync <= 2'b00;
    else rst_sync <= {rst_sync[0], 1'b1};
  end
  wire rst_n_i = rst_sync[1];

  // Configuration inputs on the bidirectional bank (input-only, driven by the host).
  wire [2:0] wpm_sel     = uio_in[2:0];
  wire       audio_en    = uio_in[3];
  wire [1:0] tone_sel    = uio_in[5:4];
  wire       display_en  = uio_in[6];
  wire       auto_repeat = uio_in[7];

  wire       tick, reload;
  wire [6:0] stage;
  wire [2:0] rom_len;
  wire [5:0] rom_pattern;
  wire       rom_space;
  wire       key, busy, element;
  wire       ready, char_done, invalid;
  wire       audio_pwm;

  morse_rom u_rom (
      .code    (stage),
      .len     (rom_len),
      .pattern (rom_pattern),
      .is_space(rom_space)
  );

  dit_timer u_timer (
      .clk    (clk),
      .rst_n  (rst_n_i),
      .wpm_sel(wpm_sel),
      .reload (reload),
      .tick   (tick)
  );

  morse_fsm u_fsm (
      .clk        (clk),
      .rst_n      (rst_n_i),
      .tick       (tick),
      .char_in    (ui_in[6:0]),
      .load       (ui_in[7]),
      .auto_repeat(auto_repeat),
      .rom_len    (rom_len),
      .rom_pattern(rom_pattern),
      .rom_space  (rom_space),
      .stage      (stage),
      .key        (key),
      .ready      (ready),
      .busy       (busy),
      .element    (element),
      .char_done  (char_done),
      .invalid    (invalid),
      .reload     (reload)
  );

  sidetone_pwm u_tone (
      .clk      (clk),
      .rst_n    (rst_n_i),
      .key      (key),
      .audio_en (audio_en),
      .tone_sel (tone_sel),
      .audio_pwm(audio_pwm)
  );

  // display_en = 0 blanks the fast-toggling diagnostic segments (element on
  // uo[3], tick on uo[6]). The handshake lines (ready, busy, char_done,
  // invalid), the key line, and the audio PWM stay live so the host protocol
  // keeps working with the display dark.
  assign uo_out = {audio_pwm,             // uo[7]: audio_pwm (7-seg dp)
                   tick & display_en,     // uo[6]: tick      (7-seg g)
                   invalid,               // uo[5]: invalid   (7-seg f)
                   char_done,             // uo[4]: char_done (7-seg e)
                   element & display_en,  // uo[3]: element   (7-seg d)
                   busy,                  // uo[2]: busy      (7-seg c)
                   ready,                 // uo[1]: ready     (7-seg b)
                   key};                  // uo[0]: key       (7-seg a)

  // The design never drives a bidirectional pin.
  assign uio_out = 8'h00;
  assign uio_oe  = 8'h00;

  // List all unused inputs to prevent warnings
  wire _unused = &{ena, 1'b0};

endmodule
