# tt_um_morse_converter — ASCII to Morse Code Converter

[![gds](../../actions/workflows/gds.yaml/badge.svg)](../../actions/workflows/gds.yaml)
[![test](../../actions/workflows/test.yaml/badge.svg)](../../actions/workflows/test.yaml)
[![docs](../../actions/workflows/docs.yaml/badge.svg)](../../actions/workflows/docs.yaml)
[![fpga](../../actions/workflows/fpga.yaml/badge.svg)](../../actions/workflows/fpga.yaml)

A [Tiny Tapeout](https://tinytapeout.com) project (TTSKY26c, SkyWater 130nm,
1×1 tile) that converts ASCII characters to ITU-R M.1677-1 Morse code in
hardware. Characters arrive over a simple load/ready handshake; the chip owns
all timing and serializes each character on a key line, as a PWM sidetone for
the [TT Audio Pmod](https://github.com/MichaelBell/tt-audio-pmod), and as
pulsing segments on the demoboard's 7-segment display.

- **Datasheet / pinout / usage:** [docs/info.md](docs/info.md)
- **Design source:** [src/](src/) — plain Verilog-2001, single clock domain,
  no latches, `uio_oe` tied to zero. One file per functional block:
  [project.v](src/project.v) (top-level pin mapping and reset),
  [morse_rom.v](src/morse_rom.v) (character encoding),
  [dit_timer.v](src/dit_timer.v) (timing),
  [morse_fsm.v](src/morse_fsm.v) (serializer + handshake),
  [sidetone_pwm.v](src/sidetone_pwm.v) (audio)
- **Host driver (MicroPython, ttboard SDK):**
  [test/morse_demo.py](test/morse_demo.py)
- **Verification:** [test/test.py](test/test.py) — 20 cocotb tests, pin-level
  only (portable to gate-level sim and microcotb)

## Highlights

- Letters, digits, and 17 punctuation characters; lowercase folded to
  uppercase; ASCII space emits a proper 7 T word gap (gaps are
  non-additive — `PARIS ` measures exactly 50 dit-times).
- Eight power-of-two speed settings from ≈5.7 WPM (beginner-friendly) down to
  a 16-clocks-per-dit simulation turbo; timing is strictly clock-proportional.
- Flow control lets a polling MicroPython script stream arbitrary text with
  no inserted pauses: `ready` rises during the trailing inter-character gap,
  giving the host a full 3 T window.
- Sidetone: 600/800/1000/440 Hz square wave, 5-bit PWM at f_clk/32, idle at
  50% duty, keying aligned to tone zero crossings to suppress clicks.

## Running the tests

```sh
cd test
pip install -r requirements.txt
make          # RTL simulation with Icarus Verilog
```

## Quick start on the demoboard

```python
import morse_demo
morse_demo.demo()   # sends "HELLO WORLD" at ~5.7 WPM
```

## License

[Apache-2.0](LICENSE)
