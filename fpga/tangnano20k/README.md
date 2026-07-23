# ASCII-to-Morse Converter on the Tang Nano 20K

Hardware prototype of the Tiny Tapeout submission on a Sipeed Tang Nano 20K
(GW2AR-LV18QN88C8/I7). The Tiny Tapeout core (`src/*.v` at the repo root) is
instantiated **unchanged**; `src/top.v` here only adapts it to the board, so
what you watch on the LEDs and hear on the buzzer is what the ASIC will do,
just 2.7x faster (27 MHz crystal vs. the recommended 10 MHz; all of the core's
time constants are clock-proportional).

The ASIC eats 7-bit ASCII over a `load`/`ready` handshake on `ui_in`, which a
board with two buttons cannot type. So the only board-specific logic in
`top.v` is a small **message player**: it walks a stored string and pushes each
character into the core exactly when the core raises `ready`, driving the same
`ui_in[7]=load` / `ui_in[6:0]=char` pins a host would. The morse timing is
produced entirely by the core; the player only paces character delivery, so it
cannot outrun the core at any speed setting.

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

## Controls (on-board)

| Control          | Action                                                     |
| ---------------- | ---------------------------------------------------------- |
| S1               | cycle the message: `SOS` -> `HELLO WORLD` -> `CQ DE VOVA`  |
| S2               | mute / unmute the sidetone                                 |
| rst_btn_n (pin 42) | short to GND to reset (restarts at `SOS`, sidetone on)   |

Each message loops forever with a word gap before it repeats. Changing the
message restarts it from the first character.

## Status LEDs (on-board, lit = active)

| LED  | Meaning                                             |
| ---- | --------------------------------------------------- |
| LED0 | key (the morse output; watch this one)              |
| LED1 | busy (a character is being sent)                    |
| LED2 | element (high through the whole of a dah, brief for a dit) |
| LED3 | char_done (one blip as each character finishes)     |
| LED4 | invalid (character has no Morse encoding)           |
| LED5 | tick (dit-rate heartbeat)                            |

LED0 is the star: it blinks the actual Morse. Read `SOS` on it as
`... --- ...`.

## The status display: external 7-segment digit

Wire a **common-cathode** 7-segment digit to header J6 (pin numbers are printed
on the board silkscreen). Put a ~330 Ω resistor in series with each segment;
common cathode goes to any GND pin. The core drives `uo_out` as segment lines,
so each lit segment is a status bit (this is the ASIC's built-in 7-seg
diagnostic, not a character readout):

| Board pin (J6) | Segment | Signal    | Board pin (J6) | Segment | Signal    |
| -------------- | ------- | --------- | -------------- | ------- | --------- |
| 25             | a       | key       | 29             | e       | char_done |
| 26             | b       | ready     | 30             | f       | invalid   |
| 27             | c       | busy      | 31             | g       | tick      |
| 28             | d       | element   | 77             | dp      | audio_pwm |

The board is fully usable without the display; the LEDs tell you everything
except `ready` and the raw `audio_pwm`.

## Audio: sidetone

`audio_pwm` (header J6, pin 85) is the core's PWM-encoded sidetone, gated by the
key. It is a 5-bit PWM stream with an ~844 kHz carrier (`f_clk / 32`) meant to
feed the TT Audio Pmod's low-pass filter. For a quick listen, connect a small
**passive piezo** (which is capacitive and low-passes on its own) between pin 85
and GND through a ~330 Ω series resistor; you will hear the ~1.19 kHz tone
keyed in Morse. S2 mutes it. For a clean look on a scope, the raw key line is
also exposed on pin 80 (J5).

## Speed select and debug pins

| Board pin | Signal      | Default                          |
| --------- | ----------- | -------------------------------- |
| 48 (J5)   | speed bit 0 | 0 (internal pull-down)           |
| 41 (J5)   | speed bit 1 | 0 (internal pull-down)           |
| 42 (J5)   | reset       | short to GND to reset            |
| 85 (J6)   | audio_pwm   | PWM sidetone                     |
| 80 (J5)   | key_line    | clean morse key line (scope)     |

`speed[1:0]` maps to `wpm_sel[1:0]` (`wpm_sel[2]` is tied low, so the core's
simulation-only turbo modes are unreachable on hardware). Default is `00`, the
slowest and most watchable. Timings at the board's 27 MHz clock:

| speed (bit1, bit0) | Jumpers               | Dit time | Speed      |
| ------------------ | --------------------- | -------- | ---------- |
| `00`               | none (default)        | ~77.7 ms | ~15 WPM (watch the LED) |
| `01`               | 48 to 3V3             | ~38.8 ms | ~31 WPM    |
| `10`               | 41 to 3V3             | ~19.4 ms | ~62 WPM    |
| `11`               | 41 and 48 to 3V3      | ~9.7 ms  | ~124 WPM (blur) |

At the ASIC's recommended 10 MHz these are ~5.7 / 11.4 / 23 / 46 WPM; the board
runs everything 2.7x faster.

**Do not move inputs onto pins 13, 71-76 or 86.** Those header pins double as
the HSPI link to the on-board BL616 USB/JTAG MCU, whose firmware can actively
drive them, strongly enough to defeat the FPGA's internal pull resistors. Pins
41/42/48 only reach the unpopulated LCD connector, and 80/85 only the empty
microSD slot, so they float cleanly.

Button debounce is ~19 ms (2^19 clocks at 27 MHz), plenty for real switches.

## Board facts baked into the port

From the Tang Nano 20K v1.2 schematic (`Tang_Nano_20K_3921`):

- 27 MHz oscillator on FPGA pin 4.
- S1 = pin 88, S2 = pin 87 (the MODE0/MODE1 config pins). Both buttons switch
  the pin to +3V3 through 330 Ω, so they are **active high**; the constraints
  enable internal pull-downs. If buttons ever appear dead or inverted on a
  different board revision, revisit the `PULL_MODE` on pins 87/88 in
  `src/tangnano20k.cst` and the polarity in `src/top.v`.
- The six orange LEDs (pins 15-20) have their anodes at +3V3 through 510 Ω,
  so they are **active low**; `top.v` inverts them.
