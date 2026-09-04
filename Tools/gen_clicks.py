#!/usr/bin/env python3
"""Generate a click-train test signal for drift measurement.

The signal is a series of short 1 kHz tone bursts ("clicks") at a fixed interval.
Played into both capture paths (system output + mic loopback) it gives the
drift checker sharp, unambiguous time markers across the whole recording.

Usage:
    python3 Tools/gen_clicks.py --out clicks.wav --duration 60 --interval 5
"""

from __future__ import annotations

import argparse
import sys

import numpy as np
import soundfile as sf

CLICK_FREQ_HZ = 1000.0
CLICK_MS = 10.0
CLICK_AMPLITUDE = 0.8
FADE_MS = 1.0  # windowing keeps the burst from clipping/splattering


def make_click(sample_rate: int) -> np.ndarray:
    """One tone burst with short raised-cosine fades on both ends."""
    n = int(round(sample_rate * CLICK_MS / 1000.0))
    t = np.arange(n, dtype=np.float64) / sample_rate
    burst = CLICK_AMPLITUDE * np.sin(2.0 * np.pi * CLICK_FREQ_HZ * t)

    fade = int(round(sample_rate * FADE_MS / 1000.0))
    if fade > 0 and 2 * fade <= n:
        ramp = 0.5 * (1.0 - np.cos(np.pi * np.arange(fade) / fade))
        burst[:fade] *= ramp
        burst[-fade:] *= ramp[::-1]
    return burst


def generate(duration_s: float, interval_s: float, sample_rate: int, first_at_s: float) -> np.ndarray:
    total = int(round(duration_s * sample_rate))
    signal = np.zeros(total, dtype=np.float64)
    click = make_click(sample_rate)

    t = first_at_s
    while t * sample_rate + len(click) <= total:
        start = int(round(t * sample_rate))
        signal[start:start + len(click)] += click
        t += interval_s
    return signal


def main() -> int:
    p = argparse.ArgumentParser(description="Generate a click-train WAV for drift testing")
    p.add_argument("--out", default="clicks.wav", help="output WAV path")
    p.add_argument("--duration", type=float, default=60.0, help="total length, seconds")
    p.add_argument("--interval", type=float, default=5.0, help="seconds between clicks")
    p.add_argument("--sr", type=int, default=48000, help="sample rate")
    p.add_argument("--first-at", type=float, default=1.0, help="time of the first click, seconds")
    args = p.parse_args()

    signal = generate(args.duration, args.interval, args.sr, args.first_at)
    sf.write(args.out, signal, args.sr, subtype="PCM_16")

    count = int(np.sum(np.abs(signal) > 0.5 * CLICK_AMPLITUDE) > 0) and len(
        range(0, int((args.duration - args.first_at) // args.interval) + 1)
    )
    print(f"{args.out}: {args.duration:g} s @ {args.sr} Hz, ~{count} clicks every {args.interval:g} s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
