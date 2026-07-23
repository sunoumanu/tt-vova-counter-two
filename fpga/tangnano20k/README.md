# ASCII-to-Morse Converter on the Tang Nano 20K

Hardware prototype of the Tiny Tapeout submission on a Sipeed Tang Nano 20K
(GW2AR-LV18QN88C8/I7). The Tiny Tapeout core (`src/*.v` at the repo root) is
instantiated **unchanged**; `src/top.v` here only adapts it to the board.

Plug the board in and **LED0 blinks `SOS` in Morse**, forever, slow enough to
read by eye. When the message ends, **all six LEDs flash once** together, then
everything goes dark for a few seconds before `SOS` starts over. Nothing else
blinks: while the Morse is going out, LED0 is the only light on the board.

The ASIC eats 7-bit ASCII over a `load`/`ready` handshake on `ui_in`, which a
board with two buttons cannot type. So the only board-specific logic in
`top.v` is a small **message player**: it loops `"SOS  "` and pushes each
character into the core exactly when the core raises `ready`, driving the same
`ui_in[7]=load` / `ui_in[6:0]=char` pins a host would. The Morse timing is
produced entirely by the core; the player only paces character delivery, so it
cannot outrun the core at any speed setting.

## Clocking: why 6.75 MHz

The core runs from a **/4 divider off the 27 MHz crystal, so 6.75 MHz**. Its
slowest speed setting is a fixed 2^21 clocks per dit, so dividing the clock is
the only way to slow the blink to a comfortable reading pace without modifying
the core. This also puts the board closer to the ASIC's recommended 10 MHz than
the raw crystal did. All board logic (player, debounce, reset) runs on the same
divided clock, so there is only one clock domain.

At the default speed you get:

| Element        | Duration |
| -------------- | -------- |
| dit (`.`)      | ~311 ms  |
| dah (`-`)      | ~932 ms  |
| gap between elements | ~311 ms |
| gap between characters | ~932 ms |
| rest between `SOS` repeats | ~4.4 s (14 dits) |

Sending `SOS` takes about 8.4 s, so the whole loop is roughly 12.7 s.

## Indicators

One cycle, start to finish:

| Phase                 | Duration        | LEDs                                  |
| --------------------- | --------------- | ------------------------------------- |
| sending `SOS`         | ~8.4 s (27 dits) | LED0 alone follows the key line; LED1-5 dark |
| end-of-message gap    | ~0.9 s (3 dits)  | all dark                              |
| **flash**             | ~0.3 s (1 dit)   | all six LEDs on together, once        |
| **pause**             | ~3.1 s (10 dits) | all dark, then `SOS` starts again      |

The flash and the pause are both timed off the core's own dit tick rather than a
fixed-rate counter, so they stay proportional at every speed setting.

The rest is not invented by the wrapper: the message is `"SOS  "` with two
trailing spaces, and spaces are real Morse word gaps. The core gives 4 dits for a
space following a character and 7 for a consecutive one, which is where the
11-dit rest (1 flash + 10 pause) comes from. Want a longer or shorter pause? Add
or remove a space in the message table in `src/top.v` (and adjust `MSG_LAST`).

## Building

With the Gowin IDE (Education edition works, no license needed for GW2AR-18):
open `tangnano20k.gprj` and run Synthesize, then Place & Route. If the IDE asks
for a top module, it is `top`.

From the command line:

```sh
cd fpga/tangnano20k
gw_sh build.tcl        # e.g. C:\Gowin\Gowin_V1.9.11.03_Education_x64\IDE\bin\gw_sh.exe
```

The bitstream lands in `impl/pnr/morse_converter.fs`.

## Programming

Either of:

- **Gowin Programmer** (installed next to the IDE): scan USB, pick
  *SRAM Program* (volatile, for trying it out) or *embFlash Erase, Program*
  (survives power cycles), point it at `impl/pnr/morse_converter.fs`.
- **openFPGALoader**: `openFPGALoader -b tangnano20k impl/pnr/morse_converter.fs`
  (add `-f` to write flash instead of SRAM).

## Controls

| Control            | Action                                       |
| ------------------ | -------------------------------------------- |
| S2 (pin 87)        | mute / unmute the sidetone                   |
| rst_btn_n (pin 42) | short to GND to reset (restarts `SOS`, unmuted) |

## Pins

| Board pin | Signal      | Notes                                    |
| --------- | ----------- | ---------------------------------------- |
| 4         | clk         | 27 MHz crystal                           |
| 15        | LED0        | morse key line (active low)              |
| 16-20     | LED1-5      | end-of-message flash only                |
| 87        | S2          | mute toggle                              |
| 42 (J5)   | reset       | short to GND to reset                    |
| 48 (J5)   | speed bit 0 | default 0 (internal pull-down)           |
| 41 (J5)   | speed bit 1 | default 0 (internal pull-down)           |
| 85 (J6)   | audio_pwm   | PWM sidetone (buzzer / filter)           |
| 80 (J5)   | key_line    | clean morse key line (scope)             |

## Speed select

`speed[1:0]` maps to `wpm_sel[1:0]` (`wpm_sel[2]` is tied low, so the core's
simulation-only turbo modes are unreachable on hardware). Default `00` is the
slowest and the one you want:

| speed (bit1, bit0) | Jumpers          | Dit time | Speed    |
| ------------------ | ---------------- | -------- | -------- |
| `00`               | none (default)   | ~311 ms  | ~4 WPM (read it by eye) |
| `01`               | 48 to 3V3        | ~155 ms  | ~8 WPM   |
| `10`               | 41 to 3V3        | ~78 ms   | ~15 WPM  |
| `11`               | 41 and 48 to 3V3 | ~39 ms   | ~31 WPM  |

## Audio: sidetone

`audio_pwm` (header J6, pin 85) is the core's PWM-encoded sidetone, gated by the
key. It is a 5-bit PWM stream with a ~211 kHz carrier (`f_core / 32`) meant to
feed the TT Audio Pmod's low-pass filter. For a quick listen, connect a small
**passive piezo** (which is capacitive and low-passes on its own) between pin 85
and GND through a ~330 Ω series resistor; you will hear the ~675 Hz tone keyed
in Morse. S2 mutes it. The raw key line is also exposed on pin 80 (J5) for a
scope.

## Board facts baked into the port

From the Tang Nano 20K v1.2 schematic (`Tang_Nano_20K_3921`):

- 27 MHz oscillator on FPGA pin 4.
- S2 = pin 87 (the MODE1 config pin). The button switches the pin to +3V3
  through 330 Ω, so it is **active high**; the constraints enable an internal
  pull-down. If the button ever appears dead or inverted on a different board
  revision, revisit the `PULL_MODE` on pin 87 in `src/tangnano20k.cst` and the
  polarity in `src/top.v`. Debounce is ~19 ms.
- The six orange LEDs (pins 15-20) have their anodes at +3V3 through 510 Ω, so
  they are **active low**; `top.v` inverts them.
- **Do not move inputs onto pins 13, 71-76 or 86.** Those header pins double as
  the HSPI link to the on-board BL616 USB/JTAG MCU, whose firmware can actively
  drive them, strongly enough to defeat the FPGA's internal pull resistors. Pins
  41/42/48 only reach the unpopulated LCD connector, and 80/85 only the empty
  microSD slot, so they float cleanly.

`core_clk` is a counter-derived clock routed onto the global clock network;
Gowin may emit a benign PR1014-style warning about generic routing for it. At
6.75 MHz there is enormous timing margin.
