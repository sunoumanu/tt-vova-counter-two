/*
 * Copyright (c) 2026 Vladimir Velikanov
 * SPDX-License-Identifier: Apache-2.0
 *
 * Serialization and handshake: element serializer and gap sequencer. Owns
 * the load/ready handshake and all status outputs. Every state transition is
 * gated on tick, so the timing is a pure multiple of the dit-time regardless
 * of clock frequency.
 */

`default_nettype none

module morse_fsm (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       tick,
    input  wire [6:0] char_in,
    input  wire       load,
    input  wire       auto_repeat,
    input  wire [2:0] rom_len,
    input  wire [5:0] rom_pattern,
    input  wire       rom_space,
    output reg  [6:0] stage,
    output wire       key,
    output reg        ready,
    output wire       busy,
    output wire       element,
    output reg        char_done,
    output reg        invalid,
    output wire       reload
);

  localparam [2:0] S_IDLE  = 3'd0,
                   S_MARK  = 3'd1,  // key down, 1 T (dit) or 3 T (dah)
                   S_GAP_I = 3'd2,  // intra-character gap, 1 T
                   S_GAP_C = 3'd3,  // inter-character gap, 3 T
                   S_GAP_W = 3'd4,  // word gap: 4 T after S_GAP_C, 7 T from idle
                   S_DISC  = 3'd5;  // invalid character, key up for 1 T

  reg [2:0] state;
  reg [2:0] dur;       // ticks elapsed in the current state
  reg [5:0] shifter;   // element pattern, current element in bit 5
  reg [2:0] elems;     // elements remaining, including the current one
  reg [2:0] word_len;  // last dur index for S_GAP_W (3 -> 4 T, 6 -> 7 T)
  reg       pending;   // staging register holds a not-yet-serialized character

  // Two-flop load synchronizer plus edge detector.
  reg [2:0] load_sync;
  wire load_rise = load_sync[1] & ~load_sync[2];
  wire accept = load_rise & ready;

  // A dah ends when dur reaches 2, a dit when dur reaches 0.
  wire [2:0] mark_len = shifter[5] ? 3'd2 : 3'd0;

  wire gap_c_end = (state == S_GAP_C) && (dur == 3'd2);
  wire gap_w_end = (state == S_GAP_W) && (dur == word_len);
  wire start_next = (gap_c_end | gap_w_end) & (pending | auto_repeat);

  assign key     = (state == S_MARK);
  assign busy    = (state != S_IDLE);
  assign element = shifter[5];
  assign reload  = (state == S_IDLE) | (tick & start_next);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state     <= S_IDLE;
      dur       <= 3'd0;
      shifter   <= 6'd0;
      elems     <= 3'd0;
      word_len  <= 3'd0;
      pending   <= 1'b0;
      stage     <= 7'd0;
      ready     <= 1'b1;
      char_done <= 1'b0;
      invalid   <= 1'b0;
      load_sync <= 3'b000;
    end else begin
      if (tick) begin
        char_done <= 1'b0;
        case (state)
          S_IDLE: begin
            if (pending) begin
              pending <= 1'b0;
              dur     <= 3'd0;
              if (rom_space) begin
                state    <= S_GAP_W;
                word_len <= 3'd6;  // full 7 T when not preceded by a character
                ready    <= 1'b1;
                invalid  <= 1'b0;
              end else if (rom_len == 3'd0) begin
                state   <= S_DISC;
                invalid <= 1'b1;
              end else begin
                state   <= S_MARK;
                shifter <= rom_pattern;
                elems   <= rom_len;
                invalid <= 1'b0;
              end
            end
          end

          S_MARK: begin
            if (dur == mark_len) begin
              dur <= 3'd0;
              if (elems == 3'd1) begin
                state <= S_GAP_C;
                ready <= 1'b1;  // staging is free: host has the full gap to load
              end else begin
                state   <= S_GAP_I;
                shifter <= {shifter[4:0], 1'b0};
                elems   <= elems - 3'd1;
              end
            end else begin
              dur <= dur + 3'd1;
            end
          end

          S_GAP_I: state <= S_MARK;

          S_GAP_C: begin
            if (dur == 3'd2) begin
              dur       <= 3'd0;
              char_done <= 1'b1;
              if (pending | auto_repeat) begin
                pending <= 1'b0;
                if (rom_space) begin
                  state    <= S_GAP_W;
                  word_len <= 3'd3;  // 4 T more: replaces, not follows, the 3 T gap
                  ready    <= 1'b1;
                  invalid  <= 1'b0;
                end else if (rom_len == 3'd0) begin
                  state   <= S_DISC;
                  invalid <= 1'b1;
                end else begin
                  state   <= S_MARK;
                  shifter <= rom_pattern;
                  elems   <= rom_len;
                  invalid <= 1'b0;
                end
              end else begin
                state <= S_IDLE;
              end
            end else begin
              dur <= dur + 3'd1;
            end
          end

          S_GAP_W: begin
            if (dur == word_len) begin
              dur       <= 3'd0;
              char_done <= 1'b1;
              if (pending | auto_repeat) begin
                pending <= 1'b0;
                if (rom_space) begin
                  state    <= S_GAP_W;
                  word_len <= 3'd6;  // consecutive spaces: full 7 T each
                  ready    <= 1'b1;
                  invalid  <= 1'b0;
                end else if (rom_len == 3'd0) begin
                  state   <= S_DISC;
                  invalid <= 1'b1;
                end else begin
                  state   <= S_MARK;
                  shifter <= rom_pattern;
                  elems   <= rom_len;
                  invalid <= 1'b0;
                end
              end else begin
                state <= S_IDLE;
              end
            end else begin
              dur <= dur + 3'd1;
            end
          end

          S_DISC: begin
            state <= S_IDLE;
            ready <= 1'b1;
          end

          default: state <= S_IDLE;
        endcase
      end

      // The accept logic comes after the FSM so that a character accepted in
      // the same cycle as a boundary tick is never lost: the non-blocking
      // writes below win, and the character starts at the next boundary.
      load_sync <= {load_sync[1:0], load};
      if (accept) begin
        stage   <= char_in;
        pending <= 1'b1;
        ready   <= 1'b0;
      end
    end
  end

endmodule
