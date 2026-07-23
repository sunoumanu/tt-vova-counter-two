/*
 * Tang Nano 20K (GW2AR-LV18QN88C8/I7) wrapper for tt_um_morse_converter.
 *
 * The Tiny Tapeout core (../../src/project.v and friends) is instantiated
 * *unchanged*; this file only adapts it to the board.
 *
 * The ASIC eats 7-bit ASCII over a load/ready handshake on ui_in, which a
 * board with two buttons cannot type. So the only board-specific logic here
 * is a small message player: it loops "SOS  " and pushes each character into
 * the core exactly when the core raises `ready`, driving the same
 * ui_in[7]=load / ui_in[6:0]=char pins a host would. The morse timing you
 * watch on the LED is produced entirely by the core; the player only paces
 * character delivery.
 *
 * The core runs from a divided clock: 27 MHz / 4 = 6.75 MHz. The core's
 * slowest speed setting is a fixed 2^21 clocks per dit, so dividing the
 * clock is the only way to slow the blink down to a comfortable reading
 * pace without touching the core. At 6.75 MHz the default dit is ~311 ms and
 * a dah ~932 ms - easy to read by eye. It also puts the board closer to the
 * ASIC's recommended 10 MHz than the raw 27 MHz crystal did.
 *
 *   LED0 (pin 15)  : the morse key line, while SOS is being sent
 *   LED0-5 (15-20) : one flash together when SOS ends, then a long dark pause
 *   S2 (pin 87)    : mute / unmute the sidetone
 *   speed[1:0]    : header jumpers, wpm_sel[1:0] (default 00 = slowest)
 *   rst_btn_n     : short header pin to GND to reset
 */

`default_nettype none

module top (
    input  wire       clk,        // pin 4, 27 MHz crystal
    input  wire       btn_mute,   // pin 87, S2, active high: mute toggle
    input  wire       rst_btn_n,  // header J5 pin 42, pull-up; short to GND to reset
    input  wire [1:0] speed,      // header J5 pins {41,48}; wpm_sel[1:0], default 2'b00
    output wire [5:0] led_n,      // on-board LEDs, active low (see below)
    output wire       audio_pwm,  // header J6 pin 85, PWM sidetone (buzzer / scope)
    output wire       key_line    // header J5 pin 80, clean morse key line (scope)
);

  // --------------------------------------------------------------------------
  // Clock divider: 27 MHz -> 6.75 MHz. Everything below runs on core_clk, so
  // there is only ever one clock domain to reason about.
  // --------------------------------------------------------------------------
  reg clk_half = 1'b0;
  reg core_clk = 1'b0;
  always @(posedge clk) begin
    clk_half <= ~clk_half;
    if (clk_half) core_clk <= ~core_clk;
  end

  // --------------------------------------------------------------------------
  // Reset: power-on reset OR'd with the external reset pin.
  // --------------------------------------------------------------------------
  reg [15:0] por_cnt = 16'd0;                 // 65536 clocks (~9.7 ms at 6.75 MHz)
  wire       por_done = &por_cnt;
  always @(posedge core_clk)
    if (!por_done) por_cnt <= por_cnt + 16'd1;

  wire rst_n = por_done & rst_btn_n;

  // --------------------------------------------------------------------------
  // Mute button: 2-flop sync + debounce + rising-edge detect + toggle.
  // --------------------------------------------------------------------------
  wire mute_clean;
  debounce #(.W(17)) u_db (                   // ~19 ms at 6.75 MHz
      .clk  (core_clk),
      .rst_n(rst_n),
      .noisy(btn_mute),
      .clean(mute_clean)
  );

  reg  mute_prev;
  reg  audio_reg;                             // audio_en, toggled by S2
  wire mute_rise = mute_clean & ~mute_prev;
  always @(posedge core_clk or negedge rst_n) begin
    if (!rst_n) begin
      mute_prev <= 1'b0;
      audio_reg <= 1'b1;                       // sidetone on by default
    end else begin
      mute_prev <= mute_clean;
      if (mute_rise) audio_reg <= ~audio_reg;
    end
  end

  // --------------------------------------------------------------------------
  // Message: "SOS  " on a loop - two trailing spaces, which are real Morse word
  // gaps rather than anything invented here. The core gives 4 dits for a space
  // that follows a character and 7 dits for a consecutive one, so the two
  // together buy an 11-dit rest: one dit of that is the LED flash and the
  // remaining ten are the quiet pause before SOS starts over.
  // --------------------------------------------------------------------------
  localparam [2:0] MSG_LAST = 3'd4;            // index of the last character

  reg [2:0] idx;
  reg [6:0] msg_char;
  always @(*) begin
    case (idx)
      3'd0:    msg_char = 7'h53;               // S
      3'd1:    msg_char = 7'h4F;               // O
      3'd2:    msg_char = 7'h53;               // S
      default: msg_char = 7'h20;               // spaces at 3 and 4 (word gaps)
    endcase
  end

  // --------------------------------------------------------------------------
  // Core instance.
  // --------------------------------------------------------------------------
  wire [7:0] uo_out;
  wire [7:0] uio_out;
  wire [7:0] uio_oe;

  wire       core_ready = uo_out[1];           // ready line from the core

  reg        load_q;                           // ui_in[7]

  // uio_in: [2:0] wpm_sel, [3] audio_en, [5:4] tone_sel, [6] display_en,
  //         [7] auto_repeat. auto_repeat stays 0: the player owns looping.
  //         display_en is on only because it ungates the tick tap on uo_out[6],
  //         which the pause blink uses as its timebase.
  wire [2:0] wpm_sel = {1'b0, speed};          // wpm_sel[2]=0, [1:0] from jumpers
  wire [7:0] uio_in  = {1'b0,       // [7]   auto_repeat off
                        1'b1,       // [6]   display_en on (ungates tick)
                        2'b10,      // [5:4] tone_sel = ~675 Hz at 6.75 MHz
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
      .clk    (core_clk),
      .rst_n  (rst_n)
  );

  // --------------------------------------------------------------------------
  // Message feeder: present msg_char, assert load when the core is ready, then
  // advance on accept (ready falls). Handshake-paced, so it cannot outrun the
  // core at any speed setting.
  // --------------------------------------------------------------------------
  wire accept = ~core_ready & load_q;

  always @(posedge core_clk or negedge rst_n) begin
    if (!rst_n) begin
      idx    <= 3'd0;
      load_q <= 1'b0;
    end else if (core_ready && !load_q) begin
      load_q <= 1'b1;                           // ready and idle: assert load
    end else if (accept) begin
      load_q <= 1'b0;                           // accepted: drop load, next char
      idx    <= (idx == MSG_LAST) ? 3'd0 : idx + 3'd1;
    end
  end

  // --------------------------------------------------------------------------
  // "Between SOS cycles" detector.
  //
  // The core is always one character ahead of the player: it accepts the next
  // character into staging while the current one is still going out. So shadow
  // that pipeline with two flags. char_done rises exactly when the core retires
  // a character and promotes staging, so promoting our flag on the same edge
  // keeps playing_space in lockstep with what the key line is actually doing.
  // playing_space is therefore true for exactly the trailing space of "SOS ",
  // i.e. the word gap before the message repeats.
  // --------------------------------------------------------------------------
  wire char_done = uo_out[4];                   // not gated by display_en
  reg  char_done_d;
  wire char_done_rise = char_done & ~char_done_d;

  reg  staged_space;                            // char sitting in core staging
  reg  playing_space;                           // char currently on the key line

  always @(posedge core_clk or negedge rst_n) begin
    if (!rst_n) begin
      char_done_d   <= 1'b0;
      staged_space  <= 1'b0;
      playing_space <= 1'b0;
    end else begin
      char_done_d <= char_done;
      if (accept)         staged_space  <= (idx >= 3'd3);
      if (char_done_rise) playing_space <= staged_space;
    end
  end

  // One flash at the top of the rest, then dark for the remainder of it. Armed
  // whenever a character is going out and cleared by the first dit tick of the
  // rest, so the flash is exactly one dit long. Timing it off the core's own
  // tick rather than a fixed-rate counter keeps it proportional at every speed
  // setting. playing_space spans both spaces without dropping, so the flash
  // cannot re-arm between them - it happens once per SOS.
  wire tick = uo_out[6];                        // one core_clk pulse per dit
  reg  flash;
  always @(posedge core_clk or negedge rst_n) begin
    if (!rst_n)              flash <= 1'b1;
    else if (!playing_space) flash <= 1'b1;     // re-arm while sending
    else if (tick)           flash <= 1'b0;     // first tick of the rest ends it
  end

  // --------------------------------------------------------------------------
  // Board outputs. While SOS goes out, LED0 alone follows the key line; during
  // the gap between repeats all six LEDs blink together. LEDs are active low.
  // --------------------------------------------------------------------------
  // playing_space is promoted off char_done's rising edge, which lands one
  // core_clk after the next character's first mark goes out. Gating on the key
  // line trims that one-cycle overlap: a real pause is silent by definition, so
  // this can never extend the pause, only end it exactly on the first mark.
  wire       in_pause = playing_space & ~uo_out[0];
  wire [5:0] led_on   = in_pause ? {6{flash}}             // rest: one flash, then dark
                                 : {5'b00000, uo_out[0]}; // sending: key only
  assign led_n     = ~led_on;
  assign key_line  =  uo_out[0];               // clean key line for a scope
  assign audio_pwm =  uo_out[7];               // PWM sidetone for a buzzer / filter

  // Unused core status taps (ready, char_done and tick are consumed above) and
  // the bidirectional bank, which the core never drives.
  wire _unused = &{uo_out[5], uo_out[3:2], uio_out, uio_oe, 1'b0};

endmodule

// Two-flop synchronizer + integrator debounce. `clean` follows `noisy` only
// after it has held steady for 2^W clocks (~19 ms at 6.75 MHz with W=17).
module debounce #(
    parameter W = 17
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
