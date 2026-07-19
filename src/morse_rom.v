/*
 * Copyright (c) 2026 Vladimir Velikanov
 * SPDX-License-Identifier: Apache-2.0
 *
 * Character encoding: ASCII -> {len, pattern} lookup. Combinational,
 * synthesized as logic. pattern is MSB-first, 0 = dit, 1 = dah, left-aligned;
 * bits beyond len are don't-care (filled with 0 here). len = 0 means
 * "no Morse encoding".
 */

`default_nettype none

module morse_rom (
    input  wire [6:0] code,
    output reg  [2:0] len,
    output reg  [5:0] pattern,
    output wire       is_space
);

  assign is_space = (code == 7'h20);

  // Fold a-z onto A-Z by clearing bit 5.
  wire [6:0] folded = (code >= 7'h61 && code <= 7'h7A) ? {code[6], 1'b0, code[4:0]} : code;

  always @(*) begin
    case (folded)
      // Letters
      7'h41:   begin len = 3'd2; pattern = 6'b010000; end  // A .-
      7'h42:   begin len = 3'd4; pattern = 6'b100000; end  // B -...
      7'h43:   begin len = 3'd4; pattern = 6'b101000; end  // C -.-.
      7'h44:   begin len = 3'd3; pattern = 6'b100000; end  // D -..
      7'h45:   begin len = 3'd1; pattern = 6'b000000; end  // E .
      7'h46:   begin len = 3'd4; pattern = 6'b001000; end  // F ..-.
      7'h47:   begin len = 3'd3; pattern = 6'b110000; end  // G --.
      7'h48:   begin len = 3'd4; pattern = 6'b000000; end  // H ....
      7'h49:   begin len = 3'd2; pattern = 6'b000000; end  // I ..
      7'h4A:   begin len = 3'd4; pattern = 6'b011100; end  // J .---
      7'h4B:   begin len = 3'd3; pattern = 6'b101000; end  // K -.-
      7'h4C:   begin len = 3'd4; pattern = 6'b010000; end  // L .-..
      7'h4D:   begin len = 3'd2; pattern = 6'b110000; end  // M --
      7'h4E:   begin len = 3'd2; pattern = 6'b100000; end  // N -.
      7'h4F:   begin len = 3'd3; pattern = 6'b111000; end  // O ---
      7'h50:   begin len = 3'd4; pattern = 6'b011000; end  // P .--.
      7'h51:   begin len = 3'd4; pattern = 6'b110100; end  // Q --.-
      7'h52:   begin len = 3'd3; pattern = 6'b010000; end  // R .-.
      7'h53:   begin len = 3'd3; pattern = 6'b000000; end  // S ...
      7'h54:   begin len = 3'd1; pattern = 6'b100000; end  // T -
      7'h55:   begin len = 3'd3; pattern = 6'b001000; end  // U ..-
      7'h56:   begin len = 3'd4; pattern = 6'b000100; end  // V ...-
      7'h57:   begin len = 3'd3; pattern = 6'b011000; end  // W .--
      7'h58:   begin len = 3'd4; pattern = 6'b100100; end  // X -..-
      7'h59:   begin len = 3'd4; pattern = 6'b101100; end  // Y -.--
      7'h5A:   begin len = 3'd4; pattern = 6'b110000; end  // Z --..
      // Digits
      7'h30:   begin len = 3'd5; pattern = 6'b111110; end  // 0 -----
      7'h31:   begin len = 3'd5; pattern = 6'b011110; end  // 1 .----
      7'h32:   begin len = 3'd5; pattern = 6'b001110; end  // 2 ..---
      7'h33:   begin len = 3'd5; pattern = 6'b000110; end  // 3 ...--
      7'h34:   begin len = 3'd5; pattern = 6'b000010; end  // 4 ....-
      7'h35:   begin len = 3'd5; pattern = 6'b000000; end  // 5 .....
      7'h36:   begin len = 3'd5; pattern = 6'b100000; end  // 6 -....
      7'h37:   begin len = 3'd5; pattern = 6'b110000; end  // 7 --...
      7'h38:   begin len = 3'd5; pattern = 6'b111000; end  // 8 ---..
      7'h39:   begin len = 3'd5; pattern = 6'b111100; end  // 9 ----.
      // Punctuation ($ is excluded: its 7-element pattern does not fit)
      7'h2E:   begin len = 3'd6; pattern = 6'b010101; end  // . .-.-.-
      7'h2C:   begin len = 3'd6; pattern = 6'b110011; end  // , --..--
      7'h3F:   begin len = 3'd6; pattern = 6'b001100; end  // ? ..--..
      7'h27:   begin len = 3'd6; pattern = 6'b011110; end  // ' .----.
      7'h21:   begin len = 3'd6; pattern = 6'b101011; end  // ! -.-.--
      7'h2F:   begin len = 3'd5; pattern = 6'b100100; end  // / -..-.
      7'h28:   begin len = 3'd5; pattern = 6'b101100; end  // ( -.--.
      7'h29:   begin len = 3'd6; pattern = 6'b101101; end  // ) -.--.-
      7'h26:   begin len = 3'd5; pattern = 6'b010000; end  // & .-...
      7'h3A:   begin len = 3'd6; pattern = 6'b111000; end  // : ---...
      7'h3B:   begin len = 3'd6; pattern = 6'b101010; end  // ; -.-.-.
      7'h3D:   begin len = 3'd5; pattern = 6'b100010; end  // = -...-
      7'h2B:   begin len = 3'd5; pattern = 6'b010100; end  // + .-.-.
      7'h2D:   begin len = 3'd6; pattern = 6'b100001; end  // - -....-
      7'h5F:   begin len = 3'd6; pattern = 6'b001101; end  // _ ..--.-
      7'h22:   begin len = 3'd6; pattern = 6'b010010; end  // " .-..-.
      7'h40:   begin len = 3'd6; pattern = 6'b011010; end  // @ .--.-.
      default: begin len = 3'd0; pattern = 6'b000000; end  // no encoding
    endcase
  end

endmodule
