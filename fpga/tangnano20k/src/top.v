/*
 * Tang Nano 20K (GW2AR-LV18QN88C8/I7) wrapper for tt_um_morse_converter.
 *
 * The Tiny Tapeout core (../../src/project.v and friends) is instantiated
 * *unchanged*; this file only adapts it to the board, so what you see and
 * hear on the board is what the ASIC will do, just 2.7x faster (27 MHz
 * crystal vs. the recommended 10 MHz; every time constant in the core is
 * clock-proportional).
 *
 * The ASIC eats 7-bit ASCII over a load/ready handshake on ui_in, which a
 * board with two buttons cannot type. So the only board-specific logic here
 * is a small message player: it walks a stored string and pushes each
 * character into the core exactly when the core raises `ready`, driving the
 * same ui_in[7]=load / ui_in[6:0]=char pins the host would. The morse timing
 * you watch on the LED and hear on the buzzer is produced entirely by the
 * core; the player only paces character delivery.
 *
 *   S1 (pin 88) : cycle the message      SOS -> HELLO WORLD -> CQ DE VOVA
 *   S2 (pin 87) : mute / unmute the sidetone
 *   speed[1:0]  : header jumpers, wpm_sel[1:0] (default 00 = ~15 WPM)
 *   rst_btn_n   : short header pin to GND to reset
 *
 * Reset sources (any of): power-on reset (~2.4 ms after configuration) or
 * the rst_btn_n header pin jumpered to GND. The core has its own reset
 * synchronizer, so a clean level is all it needs.
 */

`default_nettype none

module top (
    input  wire       clk,        // pin 4, 27 MHz crystal
    input  wire       btn_s1,     // pin 88, S1, active high: next message
    input  wire       btn_s2,     // pin 87, S2, active high: mute toggle
    input  wire       rst_btn_n,  // header J5 pin 42, pull-up; short to GND to reset
    input  wire [1:0] speed,      // header J5 pins {41,48}; wpm_sel[1:0], default 2'b00
    output wire [7:0] seg,        // header J6: {dp, g, f, e, d, c, b, a}, active high
    output wire [5:0] led_n,      // on-board LEDs, active low
    output wire       audio_pwm,  // header J6 pin 85, PWM sidetone (buzzer / scope)
    output wire       key_line    // header J5 pin 80, clean morse key line (scope)
);

  // --------------------------------------------------------------------------
  // Reset: power-on reset OR'd with the external reset pin.
  // --------------------------------------------------------------------------
  reg [15:0] por_cnt = 16'd0;                 // 65536 clocks (~2.4 ms at 27 MHz)
  wire       por_done = &por_cnt;
  always @(posedge clk)
    if (!por_done) por_cnt <= por_cnt + 16'd1;

  wire rst_n = por_done & rst_btn_n;

  // --------------------------------------------------------------------------
  // Buttons: 2-flop sync + debounce + rising-edge detect.
  // --------------------------------------------------------------------------
  wire s1_clean, s2_clean;
  debounce #(.W(19)) u_db1 (.clk(clk), .rst_n(rst_n), .noisy(btn_s1), .clean(s1_clean));
  debounce #(.W(19)) u_db2 (.clk(clk), .rst_n(rst_n), .noisy(btn_s2), .clean(s2_clean));

  reg s1_prev, s2_prev;
  always @(posedge clk or negedge rst_n)
    if (!rst_n) {s1_prev, s2_prev} <= 2'b00;
    else        {s1_prev, s2_prev} <= {s1_clean, s2_clean};

  wire s1_rise = s1_clean & ~s1_prev;         // message advance
  wire s2_rise = s2_clean & ~s2_prev;         // mute toggle

  // --------------------------------------------------------------------------
  // Configuration registers driven onto the core's uio_in bank.
  // --------------------------------------------------------------------------
  reg [1:0] msg_sel;                          // 0..2, selects the message
  reg       audio_reg;                        // audio_en, toggled by S2
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      msg_sel   <= 2'd0;
      audio_reg <= 1'b1;                       // sidetone on by default
    end else begin
      if (s1_rise) msg_sel   <= (msg_sel == 2'd2) ? 2'd0 : msg_sel + 2'd1;
      if (s2_rise) audio_reg <= ~audio_reg;
    end
  end

  // --------------------------------------------------------------------------
  // Message ROM: msg_char / msg_len as a function of {msg_sel, idx}.
  // A trailing space in each message gives a word gap before it loops.
  // --------------------------------------------------------------------------
  reg [3:0] idx;
  reg [6:0] msg_char;
  reg [3:0] msg_len;
  always @(*) begin
    case (msg_sel)
      2'd0: begin                              // "SOS "
        msg_len = 4'd4;
        case (idx)
          4'd0:    msg_char = 7'h53;           // S
          4'd1:    msg_char = 7'h4F;           // O
          4'd2:    msg_char = 7'h53;           // S
          default: msg_char = 7'h20;           // space
        endcase
      end
      2'd1: begin                              // "HELLO WORLD "
        msg_len = 4'd12;
        case (idx)
          4'd0:    msg_char = 7'h48;           // H
          4'd1:    msg_char = 7'h45;           // E
          4'd2:    msg_char = 7'h4C;           // L
          4'd3:    msg_char = 7'h4C;           // L
          4'd4:    msg_char = 7'h4F;           // O
          4'd5:    msg_char = 7'h20;           // space
          4'd6:    msg_char = 7'h57;           // W
          4'd7:    msg_char = 7'h4F;           // O
          4'd8:    msg_char = 7'h52;           // R
          4'd9:    msg_char = 7'h4C;           // L
          4'd10:   msg_char = 7'h44;           // D
          default: msg_char = 7'h20;           // space
        endcase
      end
      default: begin                           // "CQ DE VOVA "
        msg_len = 4'd11;
        case (idx)
          4'd0:    msg_char = 7'h43;           // C
          4'd1:    msg_char = 7'h51;           // Q
          4'd2:    msg_char = 7'h20;           // space
          4'd3:    msg_char = 7'h44;           // D
          4'd4:    msg_char = 7'h45;           // E
          4'd5:    msg_char = 7'h20;           // space
          4'd6:    msg_char = 7'h56;           // V
          4'd7:    msg_char = 7'h4F;           // O
          4'd8:    msg_char = 7'h56;           // V
          4'd9:    msg_char = 7'h41;           // A
          default: msg_char = 7'h20;           // space
        endcase
      end
    endcase
  end

  wire msg_last = (idx == msg_len - 4'd1);

  // --------------------------------------------------------------------------
  // Core instance + status extraction (done first so the feeder can read it).
  // --------------------------------------------------------------------------
  wire [7:0] uo_out;
  wire [7:0] uio_out;
  wire [7:0] uio_oe;

  wire       core_ready = uo_out[1];           // ready line from the core

  reg  load_q;                                 // ui_in[7]

  // uio_in: [2:0] wpm_sel, [3] audio_en, [5:4] tone_sel, [6] display_en,
  //         [7] auto_repeat. auto_repeat stays 0: the player owns looping.
  wire [2:0] wpm_sel = {1'b0, speed};          // wpm_sel[2]=0, [1:0] from jumpers
  wire [7:0] uio_in  = {1'b0,       // [7]   auto_repeat off
                        1'b1,       // [6]   display_en on
                        2'b11,      // [5:4] tone_sel = ~1.19 kHz at 27 MHz
                        audio_reg,  // [3]   audio_en
                        wpm_sel};   // [2:0] speed

  wire [7:0] ui_in = {load_q, msg_char};       // [7]=load, [6:0]=char

  tt_um_morse_converter dut (
      .ui_in  (ui_in),
      .uo_out (uo_out),
      .uio_in (uio_in),
      .uio_out(uio_out),
      .uio_oe (uio_oe),
      .ena    (1'b1),
      .clk    (clk),
      .rst_n  (rst_n)
  );

  // --------------------------------------------------------------------------
  // Message feeder: present msg_char, pulse load when the core is ready, then
  // advance on accept (ready falls). Handshake-paced, so it cannot outrun the
  // core no matter the speed setting. Restarts at index 0 when the message
  // changes.
  // --------------------------------------------------------------------------
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      idx    <= 4'd0;
      load_q <= 1'b0;
    end else if (s1_rise) begin
      idx    <= 4'd0;                           // fresh start on message change
      load_q <= 1'b0;
    end else if (core_ready && !load_q) begin
      load_q <= 1'b1;                           // ready and idle: assert load
    end else if (!core_ready && load_q) begin
      load_q <= 1'b0;                           // accepted: drop load, next char
      idx    <= msg_last ? 4'd0 : idx + 4'd1;
    end
  end

  // --------------------------------------------------------------------------
  // Board outputs.
  // --------------------------------------------------------------------------
  // External common-cathode 7-segment digit, active-high segments. The core
  // already lays uo_out out as segments: a=key, b=ready, c=busy, d=element,
  // e=char_done, f=invalid, g=tick, dp=audio_pwm.
  assign seg = uo_out;

  // On-board LEDs (active low): 0 key, 1 busy, 2 element, 3 char_done,
  // 4 invalid, 5 tick.
  assign led_n = ~{uo_out[6],   // LED5: tick      (dit-rate heartbeat)
                   uo_out[5],   // LED4: invalid
                   uo_out[4],   // LED3: char_done
                   uo_out[3],   // LED2: element   (high through a dah)
                   uo_out[2],   // LED1: busy
                   uo_out[0]};  // LED0: key       (the morse output)

  assign audio_pwm = uo_out[7];                // PWM sidetone for a buzzer / filter
  assign key_line  = uo_out[0];                // clean key line for a scope

  // The core never drives the bidirectional bank.
  wire _unused = &{uio_out, uio_oe, 1'b0};

endmodule

// Two-flop synchronizer + integrator debounce. `clean` follows `noisy` only
// after it has held steady for 2^W clocks (~19 ms at 27 MHz with W=19).
module debounce #(
    parameter W = 19
) (
    input  wire clk,
    input  wire rst_n,
    input  wire noisy,
    output reg  clean
);
  reg          s0, s1;
  reg  [W-1:0] cnt;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s0    <= 1'b0;
      s1    <= 1'b0;
      cnt   <= {W{1'b0}};
      clean <= 1'b0;
    end else begin
      s0 <= noisy;
      s1 <= s0;
      if (s1 == clean) begin
        cnt <= {W{1'b0}};                      // matches current level: hold
      end else begin
        cnt <= cnt + {{(W-1){1'b0}}, 1'b1};
        if (&cnt) clean <= s1;                 // stable long enough: adopt it
      end
    end
  end
endmodule
