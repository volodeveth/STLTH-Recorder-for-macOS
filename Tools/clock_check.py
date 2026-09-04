#!/usr/bin/env python3
"""Measure capture-clock drift inside a single track.

`drift_check.py` compares the two tracks against each other. This tool answers a
different question: does the recording clock stay aligned with the *playback* clock
over a long session? A click train played at a known interval is recorded, and the
clicks are compared against the ideal grid anchored at the first one.

Useful when only one channel carries signal — e.g. a bench with no microphone —
and as an independent check on the "one aggregate device, one clock" claim.

Usage:
    python3 Tools/clock_check.py <session-dir>/system.caf [--interval 5] [--threshold 0.3]
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
import soundfile as sf

sys.path.insert(0, str(Path(__file__).resolve().parent))

from drift_check import DriftError, detect_clicks, envelope, load_mono  # noqa: E402


def analyse(path: Path, interval_s: float) -> dict:
    if not path.exists():
        raise DriftError(f"файл не знайдено: {path}")

    signal, sample_rate = load_mono(path)
    env = envelope(signal, sample_rate)
    peaks = detect_clicks(env, sample_rate, interval_s * 0.5)

    if peaks.size < 2:
        raise DriftError(f"знайдено лише {peaks.size} клік(ів) — сигналу немає або він завтихий")

    times = peaks / sample_rate
    # Ideal grid anchored at the first click.
    expected = times[0] + np.arange(times.size) * interval_s
    deviations = times - expected

    # Linear trend = systematic clock difference between capture and playback.
    slope, _ = np.polyfit(times, deviations, 1)

    return {
        "sample_rate": sample_rate,
        "duration_s": signal.size / sample_rate,
        "clicks": int(peaks.size),
        "expected_clicks": int(round((times[-1] - times[0]) / interval_s)) + 1,
        "deviation_max_abs_s": float(np.max(np.abs(deviations))),
        "deviation_last_s": float(deviations[-1]),
        "drift_ppm": float(slope * 1_000_000),
        "drift_per_hour_s": float(slope * 3600),
    }


def main() -> int:
    p = argparse.ArgumentParser(description="Measure capture clock drift within one track")
    p.add_argument("track", type=Path, help="path to a .caf/.wav track containing the click train")
    p.add_argument("--interval", type=float, default=5.0, help="seconds between clicks")
    p.add_argument("--threshold", type=float, default=0.3, help="acceptance threshold, seconds")
    args = p.parse_args()

    try:
        result = analyse(args.track, args.interval)
    except DriftError as exc:
        print(f"ПОМИЛКА: {exc}", file=sys.stderr)
        return 2

    missing = result["expected_clicks"] - result["clicks"]
    print(f"""Трек:              {args.track.name}
Тривалість:        {result['duration_s']:.3f} с
Кліків знайдено:   {result['clicks']} з {result['expected_clicks']} очікуваних{'' if missing == 0 else f' (⚠️ бракує {missing})'}

Максимальне відхилення від ідеальної сітки: {result['deviation_max_abs_s'] * 1000:.1f} мс
Відхилення останнього кліка:               {result['deviation_last_s'] * 1000:+.1f} мс
Дрейф годинника:                           {result['drift_ppm']:+.1f} ppm
Екстраполяція на годину:                   {result['drift_per_hour_s'] * 1000:+.1f} мс/год

Поріг приймання: {args.threshold * 1000:.0f} мс""")

    ok = result["deviation_max_abs_s"] <= args.threshold and missing == 0
    print("РЕЗУЛЬТАТ: ✅ ПРОЙДЕНО" if ok else "РЕЗУЛЬТАТ: ❌ НЕ ПРОЙДЕНО")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
