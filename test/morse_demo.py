# SPDX-FileCopyrightText: © 2026 Vladimir Velikanov
# SPDX-License-Identifier: Apache-2.0
"""MicroPython host driver for tt_um_morse_converter (spec section 7.3).

Runs on the Tiny Tapeout demoboard RP2350 with the ttboard SDK. The chip owns
all Morse timing; this script only feeds bytes and respects the ready flag.

Usage from the REPL:

    >>> import morse_demo
    >>> morse_demo.demo()          # sends "HELLO WORLD" at the slowest speed

or, with an already configured DemoBoard:

    >>> sender = morse_demo.MorseSender(tt)
    >>> sender.configure(wpm_sel=0, audio=True, tone=0)
    >>> sender.send("CQ CQ CQ DE TT")
"""

import time

# uo_out bit masks
KEY = 1 << 0
READY = 1 << 1
BUSY = 1 << 2
ELEMENT = 1 << 3
CHAR_DONE = 1 << 4
INVALID = 1 << 5
TICK = 1 << 6
AUDIO_PWM = 1 << 7

LOAD = 0x80  # ui_in[7]


class MorseSender:
    """Wraps the load/ready handshake. Never times Morse elements itself."""

    def __init__(self, tt):
        self.tt = tt
        self._last = None

    def configure(self, wpm_sel=0, audio=True, tone=0, display=False,
                  auto_repeat=False):
        """Write the uio_in configuration byte."""
        val = (wpm_sel & 0x07)
        if audio:
            val |= 0x08
        val |= (tone & 0x03) << 4
        if display:
            val |= 0x40
        if auto_repeat:
            val |= 0x80
        self.tt.uio_in.value = val

    def _uo(self):
        return int(self.tt.uo_out.value)

    def _check_invalid(self):
        # invalid stays latched until the next successful load, so checking
        # here costs nothing and never stalls the stream.
        if self._last is not None and (self._uo() & INVALID):
            print("warning: no Morse encoding for %r, character skipped"
                  % self._last)
            self._last = None

    def send_char(self, c, timeout_ms=30000):
        """Poll ready, write char_in, strobe load. Returns once the character
        has been accepted (not once it has finished sounding)."""
        deadline = time.ticks_add(time.ticks_ms(), timeout_ms)
        while not (self._uo() & READY):
            if time.ticks_diff(deadline, time.ticks_ms()) < 0:
                raise RuntimeError("timeout waiting for ready")
        self._check_invalid()
        code = ord(c) & 0x7F
        self.tt.ui_in.value = code
        self.tt.ui_in.value = code | LOAD
        self.tt.ui_in.value = code
        self._last = c

    def wait_idle(self, timeout_ms=120000):
        """Block until busy falls."""
        deadline = time.ticks_add(time.ticks_ms(), timeout_ms)
        while self._uo() & BUSY:
            if time.ticks_diff(deadline, time.ticks_ms()) < 0:
                raise RuntimeError("timeout waiting for idle")

    def send(self, text, timeout_ms=30000):
        """Send a string character by character, blocking until the final
        character has fully completed (busy falls exactly when the final
        char_done pulse begins)."""
        for c in text:
            self.send_char(c, timeout_ms)
        self.wait_idle()
        self._check_invalid()


def demo():
    """Canonical bring-up check: send "HELLO WORLD" at the slowest speed."""
    from ttboard.demoboard import DemoBoard

    tt = DemoBoard.get()
    tt.shuttle.tt_um_morse_converter.enable()
    tt.clock_project_PWM(10e6)

    # The design leaves the whole bidirectional bank as chip inputs; the RP2
    # supplies the configuration byte.
    tt.uio_oe_pico.value = 0xFF

    sender = MorseSender(tt)
    sender.configure(wpm_sel=0, audio=True, tone=0)

    tt.reset_project(True)
    time.sleep_ms(10)
    tt.reset_project(False)
    time.sleep_ms(10)

    print("sending HELLO WORLD at ~5.7 WPM; listen on the Audio Pmod "
          "or watch uo[0]")
    sender.send("HELLO WORLD")
    print("done")


if __name__ == "__main__":
    demo()
