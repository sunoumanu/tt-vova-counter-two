# SPDX-FileCopyrightText: © 2026 Vladimir Velikanov
# SPDX-License-Identifier: Apache-2.0
#
# cocotb tests for tt_um_morse_converter (spec section 8.2).
#
# The tests interact with the design only through the Tiny Tapeout pins so
# they stay portable to gate-level simulation and to microcotb on the
# demoboard. They are written to run under both cocotb 1.9.x and 2.0.x.
#
# Most tests run at wpm_sel = 7 (16 clocks per dit); audio tests use
# wpm_sel = 4 so that key-down intervals are long compared with the sidetone
# period.

import inspect

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge

# uo_out bit masks
KEY = 1 << 0
READY = 1 << 1
BUSY = 1 << 2
ELEMENT = 1 << 3
CHAR_DONE = 1 << 4
INVALID = 1 << 5
TICK = 1 << 6
AUDIO = 1 << 7

# Dit length in clock cycles per wpm_sel setting.
DIT_CLKS = {0: 2**21, 1: 2**20, 2: 2**19, 3: 2**18, 4: 2**16, 5: 2**12, 6: 2**8, 7: 2**4}

# Reference ITU-R M.1677-1 table (independent of the RTL ROM).
MORSE = {
    "A": ".-", "B": "-...", "C": "-.-.", "D": "-..", "E": ".", "F": "..-.",
    "G": "--.", "H": "....", "I": "..", "J": ".---", "K": "-.-", "L": ".-..",
    "M": "--", "N": "-.", "O": "---", "P": ".--.", "Q": "--.-", "R": ".-.",
    "S": "...", "T": "-", "U": "..-", "V": "...-", "W": ".--", "X": "-..-",
    "Y": "-.--", "Z": "--..",
    "0": "-----", "1": ".----", "2": "..---", "3": "...--", "4": "....-",
    "5": ".....", "6": "-....", "7": "--...", "8": "---..", "9": "----.",
    ".": ".-.-.-", ",": "--..--", "?": "..--..", "'": ".----.", "!": "-.-.--",
    "/": "-..-.", "(": "-.--.", ")": "-.--.-", "&": ".-...", ":": "---...",
    ";": "-.-.-.", "=": "-...-", "+": ".-.-.", "-": "-....-", "_": "..--.-",
    '"': ".-..-.", "@": ".--.-.",
}


def config_byte(wpm=7, audio=0, tone=0, display=1, repeat_=0):
    """Build the uio_in configuration byte."""
    return (wpm & 7) | ((1 if audio else 0) << 3) | ((tone & 3) << 4) \
        | ((1 if display else 0) << 6) | ((1 if repeat_ else 0) << 7)


def uo(dut):
    return int(dut.uo_out.value)


def start_clock(dut):
    clock = Clock(dut.clk, 100, "ns")  # 10 MHz
    started = clock.start()
    if inspect.iscoroutine(started):  # cocotb 1.x: start() is a coroutine
        cocotb.start_soon(started)


async def reset(dut, uio=None):
    if uio is None:
        uio = config_byte()
    start_clock(dut)
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = uio
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 10)


async def send_char(dut, ch, timeout=1_000_000):
    """Poll ready, place the character, strobe load. Returns after the strobe."""
    n = 0
    while not (uo(dut) & READY):
        await FallingEdge(dut.clk)
        n += 1
        assert n < timeout, "timeout waiting for ready"
    code = ord(ch) & 0x7F
    dut.ui_in.value = code
    await ClockCycles(dut.clk, 1)
    dut.ui_in.value = code | 0x80
    await ClockCycles(dut.clk, 4)
    dut.ui_in.value = code
    await ClockCycles(dut.clk, 1)


async def send_text(dut, text):
    for ch in text:
        await send_char(dut, ch)


def expected_runs(text, dit):
    """Expected (level, cycles) run-length list on the key line, from the
    first mark to the end of the final trailing gap (where busy falls)."""
    runs = []

    def add(level, dits):
        if runs and runs[-1][0] == level:
            runs[-1][1] += dits
        else:
            runs.append([level, dits])

    prev = None
    for ch in text:
        if ch == " ":
            # A word gap replaces the inter-character gap (3 T already
            # emitted), so it adds 4 T after a character, 7 T otherwise.
            add(0, 4 if (prev is not None and prev != " ") else 7)
        else:
            for e in MORSE[ch.upper()]:
                add(1, 3 if e == "-" else 1)
                add(0, 1)
            runs[-1][1] += 2  # trailing intra gap becomes the 3 T char gap
        prev = ch
    return [(lvl, d * dit) for lvl, d in runs]


async def record_runs(dut, max_cycles=5_000_000):
    """Sample the key line every clock from the first key-down until busy
    falls. Returns a list of (level, cycles, element) runs; element is the
    element flag captured at the start of each mark run (None for gaps)."""
    n = 0
    while not (uo(dut) & KEY):
        await FallingEdge(dut.clk)
        n += 1
        assert n < max_cycles, "timeout waiting for the first mark"
    runs = []
    level = 1
    count = 0
    elem = 1 if (uo(dut) & ELEMENT) else 0
    for _ in range(max_cycles):
        v = uo(dut)
        k = 1 if (v & KEY) else 0
        if k == 0 and not (v & BUSY):
            runs.append((level, count, elem))
            return runs
        if k == level:
            count += 1
        else:
            runs.append((level, count, elem))
            level = k
            count = 1
            elem = (1 if (v & ELEMENT) else 0) if k else None
        await FallingEdge(dut.clk)
    raise AssertionError("timeout while recording the key line")


async def record_for(dut, cycles):
    """Sample the key line for a fixed number of cycles, starting at the
    first key-down. Returns (level, cycles) runs; the last run is partial."""
    n = 0
    while not (uo(dut) & KEY):
        await FallingEdge(dut.clk)
        n += 1
        assert n < 5_000_000, "timeout waiting for the first mark"
    runs = []
    level = 1
    count = 0
    for _ in range(cycles):
        k = 1 if (uo(dut) & KEY) else 0
        if k == level:
            count += 1
        else:
            runs.append((level, count))
            level = k
            count = 1
        await FallingEdge(dut.clk)
    runs.append((level, count))
    return runs


async def check_text(dut, text, wpm=7, check_element=True):
    """Stream text with ready-polling and compare the key line, cycle for
    cycle, against the reference Morse timing."""
    dit = DIT_CLKS[wpm]
    cocotb.start_soon(send_text(dut, text))
    runs = await record_runs(dut)
    got = [(lvl, cyc) for lvl, cyc, _ in runs]
    exp = expected_runs(text, dit)
    assert got == exp, "key runs for %r: got %r, expected %r" % (text, got, exp)
    if check_element:
        for lvl, cyc, elem in runs:
            if lvl == 1:
                want = 1 if cyc == 3 * dit else 0
                assert elem == want, "element flag wrong on a %d-cycle mark" % cyc
    return runs


async def measure_pwm_window(dut):
    """Count high samples of audio_pwm over one 32-clock PWM period."""
    highs = 0
    for _ in range(32):
        if uo(dut) & AUDIO:
            highs += 1
        await FallingEdge(dut.clk)
    return highs


# --------------------------------------------------------------------------
# 1. Reset state
# --------------------------------------------------------------------------
@cocotb.test()
async def test_reset_state(dut):
    await reset(dut)
    v = uo(dut)
    assert not (v & KEY), "key must be low after reset"
    assert v & READY, "ready must be high after reset"
    assert not (v & BUSY), "busy must be low after reset"
    assert not (v & INVALID), "invalid must be low after reset"
    # And it stays that way with no input.
    await ClockCycles(dut.clk, 200)
    v = uo(dut)
    assert not (v & KEY) and (v & READY) and not (v & BUSY)


# --------------------------------------------------------------------------
# 2. Single dit ('E'), plus char_done pulse width
# --------------------------------------------------------------------------
@cocotb.test()
async def test_single_dit_e(dut):
    await reset(dut)
    dit = DIT_CLKS[7]
    await check_text(dut, "E")
    # busy fell at the end of the inter-character gap: char_done pulses
    # there for one dit-time.
    assert uo(dut) & CHAR_DONE, "char_done must pulse when the character completes"
    await ClockCycles(dut.clk, 2 * dit)
    assert not (uo(dut) & CHAR_DONE), "char_done must be one dit-time wide"


# --------------------------------------------------------------------------
# 3. Single dah ('T')
# --------------------------------------------------------------------------
@cocotb.test()
async def test_single_dah_t(dut):
    await reset(dut)
    await check_text(dut, "T")


# --------------------------------------------------------------------------
# 4. Multi-element ('A': mark 1 T, gap 1 T, mark 3 T)
# --------------------------------------------------------------------------
@cocotb.test()
async def test_multi_element_a(dut):
    await reset(dut)
    runs = await check_text(dut, "A")
    dit = DIT_CLKS[7]
    assert [(l, c) for l, c, _ in runs] == [(1, dit), (0, dit), (1, 3 * dit), (0, 3 * dit)]


# --------------------------------------------------------------------------
# 5. Longest letters (J, Q: 4 elements)
# --------------------------------------------------------------------------
@cocotb.test()
async def test_longest_letters(dut):
    await reset(dut)
    await check_text(dut, "JQ")


# --------------------------------------------------------------------------
# 6. Digits ('0' = 5 dahs, '5' = 5 dits)
# --------------------------------------------------------------------------
@cocotb.test()
async def test_digits(dut):
    await reset(dut)
    await check_text(dut, "05")


# --------------------------------------------------------------------------
# 7. Punctuation
# --------------------------------------------------------------------------
@cocotb.test()
async def test_punctuation(dut):
    await reset(dut)
    await check_text(dut, ".,?/")


# --------------------------------------------------------------------------
# 8. Case folding: 'a' is byte-identical to 'A'
# --------------------------------------------------------------------------
@cocotb.test()
async def test_case_folding(dut):
    await reset(dut)
    dit = DIT_CLKS[7]
    cocotb.start_soon(send_text(dut, "a"))
    runs = await record_runs(dut)
    got = [(lvl, cyc) for lvl, cyc, _ in runs]
    assert got == expected_runs("A", dit), "lowercase 'a' must match 'A': %r" % got


# --------------------------------------------------------------------------
# 9. Inter-character gap is exactly 3 T (not 4 T)
# --------------------------------------------------------------------------
@cocotb.test()
async def test_intercharacter_gap(dut):
    await reset(dut)
    dit = DIT_CLKS[7]
    runs = await check_text(dut, "EE")
    assert [(l, c) for l, c, _ in runs] == [(1, dit), (0, 3 * dit), (1, dit), (0, 3 * dit)]


# --------------------------------------------------------------------------
# 10. Word gap: 'A B' yields exactly 7 T between the two characters' marks
# --------------------------------------------------------------------------
@cocotb.test()
async def test_word_gap(dut):
    await reset(dut)
    dit = DIT_CLKS[7]
    runs = await check_text(dut, "A B")
    gaps = [(l, c) for l, c, _ in runs]
    # A: dit, gap, dah -- then 7 T word gap -- B: dah, 3x(gap, dit), 3 T gap
    assert gaps == [(1, dit), (0, dit), (1, 3 * dit), (0, 7 * dit),
                    (1, 3 * dit), (0, dit), (1, dit), (0, dit), (1, dit),
                    (0, dit), (1, dit), (0, 3 * dit)]


# --------------------------------------------------------------------------
# 11. PARIS timing: 'PARIS ' is exactly 50 T end to end
# --------------------------------------------------------------------------
@cocotb.test()
async def test_paris_timing(dut):
    for wpm in (7, 6):
        await reset(dut, uio=config_byte(wpm=wpm))
        dit = DIT_CLKS[wpm]
        runs = await check_text(dut, "PARIS ", wpm=wpm)
        total = sum(cyc for _, cyc, _ in runs)
        assert total == 50 * dit, "PARIS took %d cycles, expected %d" % (total, 50 * dit)


# --------------------------------------------------------------------------
# 12. Invalid character: '~' asserts invalid, no key-down, ready restored,
#     and the next successful load clears invalid
# --------------------------------------------------------------------------
@cocotb.test()
async def test_invalid_char(dut):
    await reset(dut)
    dit = DIT_CLKS[7]
    await send_char(dut, "~")
    # Watch for 6 dit-times: the key line must never go high.
    for _ in range(6 * dit):
        assert not (uo(dut) & KEY), "invalid character must not key down"
        await FallingEdge(dut.clk)
    v = uo(dut)
    assert v & INVALID, "invalid must be latched"
    assert v & READY, "ready must be restored after an invalid character"
    assert not (v & BUSY)
    # A successful load clears invalid.
    cocotb.start_soon(send_text(dut, "E"))
    await record_runs(dut)
    assert not (uo(dut) & INVALID), "invalid must clear on the next successful load"


# --------------------------------------------------------------------------
# 13. Handshake back-pressure: a load strobe while ready is low is ignored
# --------------------------------------------------------------------------
@cocotb.test()
async def test_backpressure(dut):
    wpm = 6
    await reset(dut, uio=config_byte(wpm=wpm))
    dit = DIT_CLKS[wpm]
    rec = cocotb.start_soon(record_runs(dut))
    await send_char(dut, "E")
    # Wait for the mark to start, then strobe 'T' while ready is low.
    n = 0
    while not (uo(dut) & KEY):
        await FallingEdge(dut.clk)
        n += 1
        assert n < 10 * dit
    assert not (uo(dut) & READY), "ready must be low while serializing"
    dut.ui_in.value = ord("T")
    await ClockCycles(dut.clk, 1)
    dut.ui_in.value = ord("T") | 0x80
    await ClockCycles(dut.clk, 4)
    dut.ui_in.value = ord("T")
    # The in-flight character must complete as a plain 'E'...
    runs = await rec
    assert [(l, c) for l, c, _ in runs] == expected_runs("E", dit)
    # ...and the ignored 'T' must not be transmitted afterwards.
    for _ in range(8 * dit):
        v = uo(dut)
        assert not (v & KEY) and not (v & BUSY), "ignored strobe must not transmit"
        await FallingEdge(dut.clk)
    assert uo(dut) & READY


# --------------------------------------------------------------------------
# 14. Streaming: a 20-character string with ready-polling has no extra gaps
# --------------------------------------------------------------------------
@cocotb.test()
async def test_streaming(dut):
    await reset(dut)
    text = "HELLO WORLD MORSE TT"
    assert len(text) == 20
    await check_text(dut, text)


# --------------------------------------------------------------------------
# 15. Speed scaling: durations scale by the expected power of two
# --------------------------------------------------------------------------
@cocotb.test()
async def test_speed_scaling(dut):
    marks = {}
    for wpm in (7, 6, 5, 4):
        await reset(dut, uio=config_byte(wpm=wpm))
        runs = await check_text(dut, "E", wpm=wpm)
        marks[wpm] = runs[0][1]
    assert marks[6] == 16 * marks[7]
    assert marks[5] == 16 * marks[6]
    assert marks[4] == 16 * marks[5]


# --------------------------------------------------------------------------
# 16. Mid-character speed change: applies only from the next character
# --------------------------------------------------------------------------
@cocotb.test()
async def test_midchar_speed_change(dut):
    await reset(dut, uio=config_byte(wpm=7))
    rec = cocotb.start_soon(record_runs(dut))
    await send_char(dut, "O")
    # Change the speed in the middle of the first dah.
    n = 0
    while not (uo(dut) & KEY):
        await FallingEdge(dut.clk)
        n += 1
        assert n < 10 * DIT_CLKS[7]
    await ClockCycles(dut.clk, 5)
    dut.uio_in.value = config_byte(wpm=6)
    runs = await rec
    got = [(lvl, cyc) for lvl, cyc, _ in runs]
    assert got == expected_runs("O", DIT_CLKS[7]), \
        "in-flight character must keep the old speed: %r" % got
    # The next character runs at the new speed.
    await check_text(dut, "E", wpm=6)


# --------------------------------------------------------------------------
# 17. Audio gating: PWM duty alternates at the tone rate while keyed and
#     holds idle (50%) duty while the key is up
# --------------------------------------------------------------------------
@cocotb.test()
async def test_audio_gating(dut):
    wpm = 4  # dit = 65536 clocks >> tone period (2 x 8333 clocks at 600 Hz)
    await reset(dut, uio=config_byte(wpm=wpm, audio=1, tone=0))
    dit = DIT_CLKS[wpm]
    await send_char(dut, "T")  # a single 3 T dah
    n = 0
    while not (uo(dut) & KEY):
        await FallingEdge(dut.clk)
        n += 1
        assert n < 10 * dit
    # Let the zero-crossing-aligned gate engage.
    await ClockCycles(dut.clk, 2 * 8333)
    # 600 windows of 32 clocks span more than one full tone period.
    duties = [await measure_pwm_window(dut) for _ in range(600)]
    assert max(duties) >= 28, "high-duty tone phase missing: %r" % max(duties)
    assert min(duties) <= 4, "low-duty tone phase missing: %r" % min(duties)
    # After key-up, the output settles back to idle duty.
    n = 0
    while uo(dut) & KEY:
        await FallingEdge(dut.clk)
        n += 1
        assert n < 10 * dit
    await ClockCycles(dut.clk, 2 * 8333 + 100)
    duties = [await measure_pwm_window(dut) for _ in range(20)]
    assert all(d == 16 for d in duties), "idle duty must be 50%%: %r" % duties


# --------------------------------------------------------------------------
# 18. Audio disable: with audio_en = 0 the PWM holds idle regardless of key
# --------------------------------------------------------------------------
@cocotb.test()
async def test_audio_disable(dut):
    wpm = 4
    await reset(dut, uio=config_byte(wpm=wpm, audio=0, tone=0))
    dit = DIT_CLKS[wpm]
    await send_char(dut, "T")
    n = 0
    while not (uo(dut) & KEY):
        await FallingEdge(dut.clk)
        n += 1
        assert n < 10 * dit
    await ClockCycles(dut.clk, 1000)
    duties = [await measure_pwm_window(dut) for _ in range(20)]
    assert all(d == 16 for d in duties), \
        "audio_pwm must hold idle duty with audio_en = 0: %r" % duties


# --------------------------------------------------------------------------
# 19. Reset during transmission
# --------------------------------------------------------------------------
@cocotb.test()
async def test_reset_during_tx(dut):
    wpm = 6
    await reset(dut, uio=config_byte(wpm=wpm))
    await send_char(dut, "O")
    n = 0
    while not (uo(dut) & KEY):
        await FallingEdge(dut.clk)
        n += 1
        assert n < 10 * DIT_CLKS[wpm]
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 1)
    await FallingEdge(dut.clk)
    assert not (uo(dut) & KEY), "reset must drive key low within one clock"
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 10)
    v = uo(dut)
    assert (v & READY) and not (v & BUSY) and not (v & KEY) and not (v & INVALID)
    # The abandoned character does not resume.
    for _ in range(8 * DIT_CLKS[wpm]):
        assert not (uo(dut) & KEY)
        await FallingEdge(dut.clk)


# --------------------------------------------------------------------------
# 20. Auto-repeat: the last character repeats with correct 3 T gaps
# --------------------------------------------------------------------------
@cocotb.test()
async def test_auto_repeat(dut):
    dit = DIT_CLKS[7]
    await reset(dut, uio=config_byte(wpm=7, repeat_=1))
    await send_char(dut, "E")
    # Record 6 full repetitions: E is (1 T mark + 3 T gap) each.
    runs = await record_for(dut, 6 * 4 * dit)
    assert len(runs) >= 8, "character must repeat with auto_repeat = 1"
    for lvl, cyc in runs[:-1]:  # last run is cut off by the fixed window
        if lvl == 1:
            assert cyc == dit, "repeated mark must be 1 T, got %d" % cyc
        else:
            assert cyc == 3 * dit, "repeat gap must be exactly 3 T, got %d" % cyc
    # Clearing auto_repeat stops the repetition after the current character.
    dut.uio_in.value = config_byte(wpm=7, repeat_=0)
    n = 0
    while uo(dut) & BUSY:
        await FallingEdge(dut.clk)
        n += 1
        assert n < 10 * 4 * dit, "auto-repeat must stop when the bit is cleared"
    await ClockCycles(dut.clk, 8 * dit)
    assert not (uo(dut) & BUSY) and not (uo(dut) & KEY)
