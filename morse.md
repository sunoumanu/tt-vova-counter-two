# tt_um_morse_converter — Specification

**Project:** ASCII-to-Morse converter for Tiny Tapeout
**Target:** TTSKY26c shuttle (SkyWater 130nm), 1×1 tile
**HDL:** Verilog-2001 (plain, synthesizable, no vendor primitives)
**Top module:** `tt_um_morse_converter`
**Template:** [ttsky-verilog-template](https://github.com/TinyTapeout/ttsky-verilog-template), structured after [tt_um_poket_animal](https://github.com/sunoumanu/tt_um_poket_animal)
**License:** Apache-2.0

---

## 1. Overview

A hardware ASCII-to-Morse code converter. The design accepts 7-bit ASCII character codes over a simple handshake on the input pins, looks each character up in an on-chip ROM, and serializes the corresponding Morse element sequence at human-perceptible speed.

The Morse stream is presented three ways simultaneously:

1. **Key line** — a raw on/off keying signal on an output pin (scope, LED, or relay).
2. **Audio** — the key line gated with a sidetone carrier, PWM-encoded for the [TT Audio Pmod](https://github.com/MichaelBell/tt-audio-pmod) on `uo[7]`.
3. **Visual** — the current element and character state rendered on the demoboard 7-segment display.

Characters are supplied by MicroPython running on the demoboard's RP2350, via the `ttboard` SDK. The chip owns all timing; the host only feeds bytes.

### 1.1 Goals

- Correct ITU-R M.1677-1 Morse encoding for letters, digits, and common punctuation.
- Timing derived entirely from the project clock, with a selectable words-per-minute rate in the range a human can follow by ear (roughly 5–20 WPM).
- Flow control that lets a MicroPython script stream arbitrary-length text without dropping characters or requiring the host to know Morse timing.
- Fit within a single Tiny Tapeout tile with margin.

### 1.2 Non-goals

- Morse decoding (audio or key input → ASCII).
- Lowercase-vs-uppercase distinction (Morse has no case; lowercase is folded to uppercase).
- Prosigns, Q-codes, or non-Latin extensions (à, ä, ñ, etc.).
- Farnsworth spacing (character speed decoupled from word speed).
- On-chip text buffering beyond a single-character staging register.

---

## 2. Definitions

| Term | Meaning |
|---|---|
| **Dit** | The base Morse time unit. All other durations are integer multiples. |
| **Dah** | Three dit-times of key-down. |
| **Element** | A single dit or dah, plus its trailing intra-character gap. |
| **Intra-character gap** | 1 dit-time of key-up between elements of one character. |
| **Inter-character gap** | 3 dit-times of key-up between characters. |
| **Word gap** | 7 dit-times of key-up, emitted for an ASCII space. |
| **PARIS speed** | Standard WPM reference: the word "PARIS" plus trailing word gap is exactly 50 dit-times. WPM = 1200 / (dit-time in ms). |

---

## 3. Interface

### 3.1 Tiny Tapeout top-level ports

Standard TT wrapper signature; `ena` is tied high by the harness and unused by the design.

```
module tt_um_morse_converter (
    input  wire [7:0] ui_in,    // dedicated inputs
    output wire [7:0] uo_out,   // dedicated outputs
    input  wire [7:0] uio_in,   // bidirectional: input path
    output wire [7:0] uio_out,  // bidirectional: output path
    output wire [7:0] uio_oe,   // bidirectional: 1 = drive
    input  wire       ena,      // always 1, ignored
    input  wire       clk,      // project clock
    input  wire       rst_n     // active-low async-assert reset
);
```

### 3.2 Pin assignment

#### Inputs — `ui_in[7:0]`

| Pin | Name | Description |
|---|---|---|
| `ui[6:0]` | `char_in[6:0]` | 7-bit ASCII code of the character to send. Sampled on the rising edge of `load`. |
| `ui[7]` | `load` | Load strobe. A 0→1 transition captures `char_in` when `ready` is high. Edge-detected and synchronized on-chip. |

Speed and mode selection use the bidirectional bank as inputs (§3.4) so that the whole ASCII code point plus the strobe fit in the dedicated input byte.

#### Outputs — `uo_out[7:0]`

| Pin | Name | Description |
|---|---|---|
| `uo[0]` | `key` | Morse key line. High = key down (mark), low = key up (space). This is the primary machine-readable result. |
| `uo[1]` | `ready` | High when the staging register is free and a new character may be loaded. |
| `uo[2]` | `busy` | High while a character is being serialized, including its trailing inter-character gap. |
| `uo[3]` | `element` | High during a dah, low during a dit. Valid only while `key` is high. Lets a logic analyzer decode elements without measuring pulse widths. |
| `uo[4]` | `char_done` | One dit-time pulse at the end of each completed character (after its inter-character gap). |
| `uo[5]` | `invalid` | Latched high if the most recently loaded character has no Morse representation. Cleared on the next successful load. |
| `uo[6]` | `tick` | Dit-rate heartbeat: one project-clock-wide pulse at each dit boundary. Diagnostic and scope-trigger aid. |
| `uo[7]` | `audio_pwm` | PWM sidetone for the TT Audio Pmod. |

The `uo[7]` assignment matches the TT Audio Pmod's mono channel so the Pmod can be plugged directly onto the output header.

#### Bidirectional — `uio[7:0]`

The design drives no bidirectional pins; `uio_oe` is hard-tied to `8'h00` and all eight lines are inputs. This keeps the bidirectional header free for the Audio Pmod's pass-through and avoids any contention with the RP2350.

| Pin | Name | Description |
|---|---|---|
| `uio[2:0]` | `wpm_sel[2:0]` | Speed select (§4.3). |
| `uio[3]` | `audio_en` | 1 = sidetone generation enabled; 0 = `audio_pwm` held at its idle level. |
| `uio[5:4]` | `tone_sel[1:0]` | Sidetone pitch select (§5.2). |
| `uio[6]` | `display_en` | 1 = 7-segment display active; 0 = display blanked (saves the demoboard LEDs during long transmissions). |
| `uio[7]` | `auto_repeat` | 1 = re-send the last character indefinitely after it completes, until `load` is strobed again or reset. Demo and burn-in aid. |

Configuration inputs are sampled continuously but only take effect at character boundaries, so changing speed mid-character cannot produce a malformed element.

### 3.3 Clock and reset

| Parameter | Value |
|---|---|
| Nominal project clock | 10 MHz |
| Supported range | 1 MHz – 50 MHz (timing scales proportionally; see §4.3) |
| Reset | `rst_n`, active low, asynchronous assert, synchronous release |

All flip-flops are clocked on the rising edge of `clk`. There are no gated clocks, latches, or multiple clock domains. Reset returns the design to `IDLE` with `key` low, `ready` high, and the audio output at idle.

### 3.4 7-segment display mapping

`uo[7:0]` is also the demoboard's 7-segment bus in the conventional `{dp, g, f, e, d, c, b, a}` order. Because this design assigns those pins to status signals, the segments light as a side effect of the status bits. This is intentional and defined rather than accidental:

- Segment `a` (`uo[0]`) follows `key` — the display's top bar flashes exactly in time with the Morse.
- Segment `b` (`uo[1]`) follows `ready`, `c` follows `busy`, `d` follows `element`.
- The decimal point (`uo[7]`) carries the PWM audio, which at audible frequencies appears as a dimly lit dot while sounding.

The visible result is a display that pulses in sync with the transmitted code. Users who want a clean scope trace should read `uo[0]` from the output Pmod header; users who want an unambiguous visual should set `display_en = 0` and watch an LED on `uo[0]`.

---

## 4. Functional requirements

### 4.1 Character set and encoding

The design implements the ITU-R M.1677-1 international Morse alphabet.

**Letters (case-folded):** `A`–`Z`. Codes `0x61`–`0x7A` are mapped to `0x41`–`0x5A` before lookup by clearing bit 5.

**Digits:** `0`–`9`, all five elements long.

**Punctuation:** `.` `,` `?` `'` `!` `/` `(` `)` `&` `:` `;` `=` `+` `-` `_` `"` `$` `@`

**Space (`0x20`):** not a code; emits a word gap (§4.2).

**Everything else:** treated as invalid — `invalid` is asserted, no key-down occurs, and the character is discarded. `ready` returns high after one dit-time so the host is never stalled by bad input.

#### 4.1.1 Encoding format

Each character is stored as a fixed-width ROM word carrying a length field and an element pattern:

| Field | Width | Meaning |
|---|---|---|
| `len` | 3 bits | Number of elements, 1–6. Zero means "no encoding" and drives `invalid`. |
| `pattern` | 6 bits | Element bits, MSB first. `0` = dit, `1` = dah. Bits beyond `len` are don't-care. |

Six element bits covers every character in the set above, including the eight-element-free punctuation cases; the longest supported sequences (`$` at seven elements) are excluded from the base set for this reason. If `$` is required, the pattern field widens to 7 bits at a cost of one extra ROM bit per entry — an implementation option, not a requirement.

The ROM is a combinational `case` statement over the 7-bit ASCII code, synthesized as logic rather than a memory macro. Sparse and irregular by nature, it is expected to optimize down substantially.

### 4.2 Timing

All durations are integer multiples of the dit-time `T`.

| Interval | Duration | Key state |
|---|---|---|
| Dit | 1 T | down |
| Dah | 3 T | down |
| Intra-character gap | 1 T | up |
| Inter-character gap | 3 T | up |
| Word gap (ASCII space) | 7 T | up |

Gaps are **non-overlapping and non-additive**: the inter-character gap replaces, rather than follows, the final intra-character gap of the preceding character. A word gap likewise replaces the inter-character gap, so a space between two letters produces exactly 7 T of key-up, not 10 T.

**Requirement:** the sequence `PARIS ` (five characters plus space) at speed setting *n* shall measure exactly 50 T of total elapsed time. This is the acceptance test for timing correctness (§8.2).

### 4.3 Speed selection

`wpm_sel[2:0]` selects the dit-time as a power-of-two divider of the project clock, so the divider is a simple counter comparison with no multipliers.

At the nominal 10 MHz project clock:

| `wpm_sel` | Divider | Dit-time | Approx. WPM | Use |
|---|---|---|---|---|
| `000` | 2²¹ | ≈ 210 ms | ≈ 5.7 | Very slow — comfortable for a beginner to copy by ear |
| `001` | 2²⁰ | ≈ 105 ms | ≈ 11.4 | Slow, clearly readable |
| `010` | 2¹⁹ | ≈ 52 ms | ≈ 23 | Moderate |
| `011` | 2¹⁸ | ≈ 26 ms | ≈ 46 | Fast — audible, not comfortably copyable |
| `100` | 2¹⁶ | ≈ 6.6 ms | ≈ 183 | Very fast, machine-readable |
| `101` | 2¹² | ≈ 0.41 ms | — | Scope/logic-analyzer work |
| `110` | 2⁸ | ≈ 26 µs | — | Fast hardware test |
| `111` | 2⁴ | 1.6 µs | — | Simulation turbo (16 clocks per dit) |

Settings `000`–`010` satisfy the "long enough for a human to recognize" requirement; `000` is the recommended default and is what the demo script selects.

Timing is strictly clock-proportional: halving the project clock doubles every duration and halves the effective WPM. The table is a convenience for the 10 MHz nominal, not a hardware constant.

### 4.4 Handshake protocol

A two-wire `load` / `ready` handshake, designed so a MicroPython script can drive it with ordinary polling and no timing knowledge:

1. On reset, `ready` = 1, `busy` = 0, `key` = 0.
2. The host places an ASCII code on `char_in` and drives `load` high.
3. On the rising edge of `load`, if `ready` is high, the character is captured into the staging register and `ready` falls.
4. The host drives `load` low. It may now prepare the next character.
5. The design serializes the character. `busy` is high throughout.
6. `ready` rises again as soon as the staging register is free — that is, during the trailing inter-character gap, not after it. This gives the host a full 3 T window to supply the next character, so a continuous stream has no inserted pauses.
7. `char_done` pulses for one dit-time when the character and its gap have fully completed.

Rules:

- A `load` edge while `ready` is low is ignored. The design never silently drops a character it acknowledged, and never accepts one it cannot hold.
- `load` is synchronized through a two-flop synchronizer and edge-detected, so the host may drive it asynchronously at any rate. Pulses shorter than two project-clock periods are not guaranteed to register.
- If no character is loaded, the design returns to `IDLE` with `key` low and remains there indefinitely. There is no idle carrier, no repeated output, and no timeout.

### 4.5 Reset behavior

Asserting `rst_n` low at any point immediately drives `key` low, silences the audio output, clears the staging register, clears `invalid`, and returns the FSM to `IDLE`. A transmission in progress is abandoned; no partial character is completed. Release of reset is synchronized internally.

---

## 5. Audio output

### 5.1 Approach

The demoboard has no on-board speaker. Audio is produced through the [TT Audio Pmod](https://github.com/MichaelBell/tt-audio-pmod), which plugs onto the output Pmod header, takes a single PWM signal on `uo[7]`, low-pass filters it, and drives either a piezo element or a headphone jack.

The Pmod's filter has a deliberately high cutoff, so the PWM carrier must be well above the audio band — a minimum of 200 kHz is recommended by its author. The design therefore generates the sidetone as a **PWM-encoded square wave**: a high-frequency PWM carrier whose duty cycle alternates between two levels at the audio-tone rate.

Concretely, `audio_pwm` is the output of an 8-bit PWM generator running at `f_clk / 256` (≈ 39 kHz at 10 MHz). Because 39 kHz sits below the recommended 200 kHz, the implementation shall instead use a 6-bit PWM at `f_clk / 64` (≈ 156 kHz at 10 MHz) or a 5-bit PWM at `f_clk / 32` (≈ 312 kHz), selected to keep the carrier above the audible band while preserving enough duty resolution for a clean square-wave tone. The 5-bit / 312 kHz option is the baseline.

### 5.2 Tone generation

- The sidetone is a square wave whose frequency is set by `tone_sel[1:0]`:

  | `tone_sel` | Approx. pitch at 10 MHz | Note |
  |---|---|---|
  | `00` | ≈ 600 Hz | Classic CW sidetone; the default |
  | `01` | ≈ 800 Hz | Brighter, cuts through noise |
  | `10` | ≈ 1000 Hz | Piezo-friendly |
  | `11` | ≈ 440 Hz | Low and mellow |

  Pitches are generated by a free-running counter and are clock-proportional like everything else.

- The tone is **gated by `key`**: audible during mark, silent during space. Gating is applied to the duty-cycle selection, not to the PWM carrier itself, so the carrier never stops and the Pmod's filter output settles cleanly at midpoint during silence rather than snapping to a rail.

- Gating transitions are aligned to tone-wave zero crossings where doing so costs no extra timing accuracy, which suppresses the click artifact at element edges. This is a quality-of-output requirement, not a correctness requirement.

- When `audio_en` = 0, the PWM output holds its idle (50% duty) level and no tone is produced. `key` and all other outputs are unaffected.

### 5.3 Alternative outputs

For users without the Audio Pmod, `uo[0]` (`key`) can drive a piezo buzzer directly through a series resistor. The result is a click-per-element rather than a tone, but the Morse rhythm is fully audible. This is documented in the project README as a fallback, not a supported interface.

---

## 6. Architecture

### 6.1 Block diagram

```
        ui[6:0] ──────────────► ┌──────────────┐
        ui[7] ─► sync/edge ───► │ Input        │
                                │ handshake    │──► ready, invalid
                                └──────┬───────┘
                                       │ char[6:0]
                                       ▼
                                ┌──────────────┐
                                │ ASCII→Morse  │
                                │ ROM (case)   │──► len[2:0], pattern[5:0]
                                └──────┬───────┘
                                       ▼
        uio[2:0] ──► ┌──────────┐  ┌──────────────┐
                     │ Dit-time │─►│ Element      │──► key, element,
                     │ divider  │  │ serializer   │    busy, char_done
                     └──────────┘  │ FSM          │
                          │        └──────┬───────┘
                          └──► tick       │ key
                                          ▼
        uio[5:3] ──────────────► ┌──────────────┐
                                 │ Sidetone +   │──► audio_pwm
                                 │ PWM          │
                                 └──────────────┘
```

### 6.2 Modules

All modules live in `src/project.v` as a single file, matching the template's convention.

| Module | Responsibility |
|---|---|
| `tt_um_morse_converter` | Top level. Pin mapping, `uio_oe` tie-off, unused-input tie-off. |
| `morse_rom` | Combinational ASCII → `{len, pattern}` lookup, including case folding and space detection. |
| `dit_timer` | Programmable clock divider producing the one-cycle `tick` at each dit boundary. Reloads on speed change at character boundaries. |
| `morse_fsm` | Element serializer and gap sequencer. Owns `key`, `busy`, `char_done`, `ready`. |
| `sidetone_pwm` | Tone counter, duty selection, PWM comparator. |

### 6.3 Serializer FSM

States:

| State | Behavior |
|---|---|
| `IDLE` | `key` = 0, `ready` = 1. Waits for a loaded character. |
| `MARK` | `key` = 1 for 1 T (dit) or 3 T (dah), per the current pattern bit. |
| `GAP_INTRA` | `key` = 0 for 1 T. Entered after every element except the last of a character. |
| `GAP_CHAR` | `key` = 0 for 3 T. `ready` rises on entry. Pulses `char_done` on exit. |
| `GAP_WORD` | `key` = 0 for 7 T. Entered for ASCII space instead of the normal element sequence. |
| `DISCARD` | Invalid character: assert `invalid`, hold `key` low for 1 T, return to `IDLE` with `ready` high. |

The element counter walks the pattern MSB-first for `len` elements. Element duration is selected by the current pattern bit; gap selection is by counter position (last element → `GAP_CHAR`, otherwise `GAP_INTRA`).

Every state transition is gated on `tick`, so the FSM advances only at dit boundaries and its state encoding is independent of the clock frequency.

### 6.4 Resource estimate

| Resource | Estimate |
|---|---|
| Flip-flops | ~60 (dit counter 21, tone counter 12, PWM 5, FSM state 3, element counter 3, pattern shift 6, staging register 7, misc. status) |
| Combinational cells | ~350–450, dominated by the ROM case statement |
| Tiles | 1 |

Comfortably within a 1×1 tile, consistent with comparable designs on prior shuttles.

---

## 7. Host-side MicroPython interface

### 7.1 Environment

The demoboard's RP2350 runs MicroPython with the [`ttboard` SDK](https://github.com/TinyTapeout/tt-micropython-firmware) pre-installed. The project is enabled from the REPL or a script by name.

### 7.2 Required configuration

The RP2 must drive the project inputs, so the mode is `ASIC_RP_CONTROL`. A project section in `config.ini` sets the defaults:

```ini
[tt_um_morse_converter]
mode = ASIC_RP_CONTROL
clock_frequency = 10e6
uio_oe_pico = 0b11111111   ; RP2 drives all config pins
uio_in = 0b00001000        ; wpm_sel=000 (slowest), audio_en=1, tone=600Hz
ui_in = 0
```

`uio_oe_pico` is set to all-outputs because the design leaves the entire bidirectional bank as chip inputs; the RP2 supplies the configuration byte.

### 7.3 Driver script

`test/morse_demo.py` shall provide, at minimum:

- `MorseSender(tt)` — a class wrapping the handshake.
- `.configure(wpm_sel, audio=True, tone=0)` — writes the `uio_in` configuration byte.
- `.send_char(c)` — polls `ready`, writes `char_in`, strobes `load`, returns once the character has been accepted (not once it has finished sounding).
- `.send(text)` — sends a string character by character, blocking until the final `char_done`.
- `.wait_idle()` — blocks until `busy` falls.

The script must not attempt to time Morse elements itself. All timing is the chip's; the host's only obligation is to respect `ready`.

### 7.4 Behavioral requirements for the host script

- Polling `ready` at any rate is safe. There is no maximum poll interval; a slow host simply produces longer inter-character gaps, which remains valid Morse.
- The script shall verify `ready` before every `load` strobe and shall never assume acceptance.
- The script shall surface `invalid` to the user (e.g. print a warning naming the offending character) rather than silently skipping it.
- A demo entry point shall send a fixed string — `"HELLO WORLD"` at `wpm_sel = 000` — as the canonical bring-up check.

---

## 8. Verification

### 8.1 Testbench

cocotb tests in `test/test.py`, run against Icarus Verilog via `test/Makefile`, with `test/tb.v` as the passive wrapper dumping `tb.fst`. Tests run at `wpm_sel = 111` (16 clocks per dit) to keep simulation time reasonable.

The same tests shall be portable to `microcotb` for hardware-in-the-loop execution on the demoboard, per the ETR demoboard guide. Tests must therefore avoid direct signal-hierarchy probing and interact only through the pins.

### 8.2 Required test cases

| # | Test | Pass criterion |
|---|---|---|
| 1 | Reset state | After reset: `key` = 0, `ready` = 1, `busy` = 0, `invalid` = 0. |
| 2 | Single dit | `E` (`0x45`) produces exactly one 1 T mark. |
| 3 | Single dah | `T` (`0x54`) produces exactly one 3 T mark. |
| 4 | Multi-element | `A` (`0x41`) produces mark 1 T, gap 1 T, mark 3 T. |
| 5 | Longest letter | `J` and `Q` (4 elements each) serialize correctly. |
| 6 | Digits | `0` (5 dahs) and `5` (5 dits) serialize correctly. |
| 7 | Punctuation | `.` `,` `?` `/` match the ITU table. |
| 8 | Case folding | `a` (`0x61`) produces byte-identical output to `A` (`0x41`). |
| 9 | Inter-character gap | Two consecutive characters are separated by exactly 3 T of key-up, not 4 T. |
| 10 | Word gap | `A` space `B` yields exactly 7 T between the two characters' marks. |
| 11 | **PARIS timing** | `"PARIS "` measures exactly 50 T end to end at every `wpm_sel` setting. |
| 12 | Invalid character | `~` (`0x7E`) asserts `invalid`, produces no key-down, and restores `ready`. |
| 13 | Handshake back-pressure | A `load` strobe while `ready` is low is ignored; the in-flight character is unaffected. |
| 14 | Streaming | A 20-character string sent with `ready`-polling produces no inserted gaps beyond the specified 3 T. |
| 15 | Speed scaling | Changing `wpm_sel` scales all durations by the expected power of two. |
| 16 | Mid-character speed change | Changing `wpm_sel` during a character does not corrupt that character; the change applies from the next character. |
| 17 | Audio gating | `audio_pwm` toggles at the tone rate while `key` is high and holds idle duty while `key` is low. |
| 18 | Audio disable | With `audio_en` = 0, `audio_pwm` holds idle regardless of `key`. |
| 19 | Reset during transmission | Mid-character reset drives `key` low within one clock and returns to `IDLE`. |
| 20 | Auto-repeat | With `auto_repeat` = 1, the last character repeats with correct inter-character gaps. |

### 8.3 CI

GitHub Actions workflows from the template, unmodified: `test` (cocotb), `gds` (hardening), `docs`, and `fpga`. All four badges must be green before submission.

### 8.4 Hardware bring-up

1. Enable the project: `tt.shuttle.tt_um_morse_converter.enable()`.
2. Set the clock to 10 MHz: `tt.clock_project_PWM(10e6)`.
3. Run the demo script and confirm `"HELLO WORLD"` is audible on the Audio Pmod and visible as pulses on `uo[0]`.
4. Verify by ear against a Morse reference, or capture `uo[0]` on a scope and measure the dit-time against §4.3.

---

## 9. Repository layout

```
tt_um_morse_converter/
├── src/
│   └── project.v            # entire design, top module tt_um_morse_converter
├── test/
│   ├── test.py              # cocotb tests (§8.2)
│   ├── tb.v                 # passive testbench wrapper, dumps tb.fst
│   ├── morse_demo.py        # MicroPython host driver (§7.3)
│   ├── Makefile
│   └── requirements.txt
├── docs/
│   └── info.md              # project datasheet, rendered on the TT site
├── .github/workflows/       # gds, docs, test, fpga
├── info.yaml                # TT metadata and pin table
├── README.md
└── LICENSE                  # Apache-2.0
```

### 9.1 `info.yaml` requirements

- `project.title`: "ASCII to Morse Code Converter"
- `project.top_module`: `tt_um_morse_converter`
- `project.tiles`: `"1x1"`
- `project.clock_hz`: `10000000`
- `project.language`: `"Verilog"`
- `pinout`: every pin in §3.2 documented with a short label; unused pins explicitly marked `""`.

### 9.2 `docs/info.md` requirements

Must cover: what the project does, how to test it (including the MicroPython snippet), which external hardware is required (TT Audio Pmod), the full pin table, and the Morse timing table from §4.2.

---

## 10. Design constraints

- **Verilog-2001 only.** No SystemVerilog constructs, no vendor primitives, no inferred memories requiring a macro.
- **`default_nettype none`** at the top of the source file, restored at the end.
- **No latches.** Every `always @(*)` block assigns all outputs on all paths.
- **No gated clocks.** Enables are implemented as flip-flop clock-enables in RTL, left to the synthesis tool.
- **All unused inputs tied off** and referenced in a `wire _unused` concatenation so the tools do not warn.
- **`uio_oe` hard-tied to zero.** The design must never drive a bidirectional pin.
- **Single clock domain.** The only asynchronous inputs are `load` and the `uio` configuration pins; `load` is two-flop synchronized, and configuration pins are sampled only at character boundaries where metastability cannot affect an in-flight element.

---

## 11. Open questions

1. **`$` support.** Its seven-element pattern does not fit the 6-bit field. Widen the pattern to 7 bits (one extra ROM bit per entry, ~90 extra bits total), or drop `$` from the character set? Dropping it is the current baseline.
2. **PWM carrier width.** 5-bit at 312 kHz is the baseline. Whether 6-bit at 156 kHz produces an audibly cleaner tone through the Pmod's filter is worth checking on hardware before freezing.
3. **Farnsworth spacing.** Genuinely useful for learners — it keeps character speed high while stretching the gaps — but it costs a second timing divider and two more configuration bits. Deferred unless tile area proves generous after the first synthesis run.
4. **Auto-repeat scope.** Currently repeats a single character. Repeating a short stored string would need a small buffer and is likely not worth the flip-flops.
