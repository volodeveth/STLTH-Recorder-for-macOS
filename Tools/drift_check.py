#!/usr/bin/env python3
"""Measure channel drift between mic.caf and system.caf of a recording session.

Method
------
Both tracks record the same click train (see gen_clicks.py). We build a smoothed
amplitude envelope for each track, detect click positions, pair them up, and report
the offset (system - mic) for every pair. Drift is how much that offset grows from
the first click to the last one. A global FFT cross-correlation of the envelopes at
the start and at the end serves as an independent cross-check.

Acceptance requirement (ТЗ): channel divergence < 300 ms over 60 minutes.

Usage:
    python3 Tools/drift_check.py <session-dir> [--threshold 0.3] [--markdown out.md]
    python3 Tools/drift_check.py --mic mic.caf --system system.caf
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
import soundfile as sf

ENVELOPE_MS = 5.0        # smoothing window for the amplitude envelope
PEAK_REL_THRESHOLD = 0.3  # peak must reach 30% of the track's strongest click
MATCH_WINDOW_S = 1.0      # a system click may be matched to a mic click within +-1 s
XCORR_SEGMENT_S = 15.0    # length of the head/tail segments used for the cross-check


class DriftError(Exception):
    """Something makes the measurement impossible (missing files, no clicks…)."""


def load_mono(path: Path) -> tuple[np.ndarray, int]:
    """Read an audio file and mix it down to mono float64."""
    data, sample_rate = sf.read(str(path), dtype="float64", always_2d=True)
    return data.mean(axis=1), sample_rate


def envelope(signal: np.ndarray, sample_rate: int) -> np.ndarray:
    """Moving-average envelope of |signal| — robust to phase differences."""
    width = max(1, int(round(sample_rate * ENVELOPE_MS / 1000.0)))
    kernel = np.ones(width, dtype=np.float64) / width
    return np.convolve(np.abs(signal), kernel, mode="same")


def detect_clicks(env: np.ndarray, sample_rate: int, min_distance_s: float) -> np.ndarray:
    """Return click positions (in samples) as local maxima above a relative threshold."""
    if env.size == 0 or env.max() <= 0:
        return np.empty(0, dtype=np.int64)

    threshold = PEAK_REL_THRESHOLD * env.max()
    min_distance = max(1, int(round(min_distance_s * sample_rate)))

    candidates = np.flatnonzero(env >= threshold)
    if candidates.size == 0:
        return np.empty(0, dtype=np.int64)

    # Group contiguous above-threshold runs, keep the strongest sample of each group,
    # then enforce the minimum spacing so one click cannot yield two peaks.
    groups = np.split(candidates, np.flatnonzero(np.diff(candidates) > 1) + 1)
    peaks = [int(g[np.argmax(env[g])]) for g in groups]

    kept: list[int] = []
    for peak in peaks:
        if kept and peak - kept[-1] < min_distance:
            if env[peak] > env[kept[-1]]:
                kept[-1] = peak
            continue
        kept.append(peak)
    return np.array(kept, dtype=np.int64)


def xcorr_lag_seconds(a: np.ndarray, b: np.ndarray, sample_rate: int, max_lag_s: float) -> float | None:
    """Lag of `a` relative to `b` via FFT cross-correlation, in seconds.

    Positive result means `a` is later than `b`.
    """
    if a.size == 0 or b.size == 0:
        return None
    max_lag = int(round(max_lag_s * sample_rate))
    size = 1 << int(np.ceil(np.log2(a.size + b.size)))

    fa = np.fft.rfft(a - a.mean(), size)
    fb = np.fft.rfft(b - b.mean(), size)
    cc = np.fft.irfft(fa * np.conj(fb), size)

    max_lag = min(max_lag, size // 2 - 1)
    if max_lag < 1:
        return None
    window = np.concatenate((cc[-max_lag:], cc[: max_lag + 1]))
    lags = np.arange(-max_lag, max_lag + 1)
    return float(lags[int(np.argmax(window))]) / sample_rate


def pair_clicks(
    mic_peaks: np.ndarray, sys_peaks: np.ndarray, sample_rate: int
) -> list[tuple[float, float, float]]:
    """Match every system click to the nearest mic click.

    Returns a list of (mic_time_s, system_time_s, offset_s).
    """
    if mic_peaks.size == 0 or sys_peaks.size == 0:
        return []

    mic_times = mic_peaks / sample_rate
    sys_times = sys_peaks / sample_rate
    pairs: list[tuple[float, float, float]] = []

    for st in sys_times:
        idx = int(np.argmin(np.abs(mic_times - st)))
        mt = float(mic_times[idx])
        if abs(st - mt) <= MATCH_WINDOW_S:
            pairs.append((mt, float(st), float(st - mt)))
    return pairs


def fit_drift(times: np.ndarray, offsets: np.ndarray) -> dict:
    """Estimate drift as the slope of offset against time, with an error bar.

    Taking (last offset − first offset) looks like the obvious measure of drift, but
    it is an estimate built from two samples: it inherits the full measurement noise
    of both and reports it as signal. On a 70-second bench run that estimator claimed
    +89 ms/hour while the regression over all fourteen clicks put the drift at
    −13 ± 60 ms/hour — statistically indistinguishable from none at all.

    A slope with a confidence interval is what makes the acceptance claim honest: it
    separates "no drift measured" from "drift too small to see in a run this short",
    and the interval shrinks as the run gets longer.
    """
    count = times.size
    if count < 3:
        return {"drift_slope_s_per_s": None, "drift_stderr_s_per_s": None,
                "drift_per_hour_s": None, "drift_ci95_per_hour_s": None,
                "fit_residual_rms_s": None}

    slope, intercept = np.polyfit(times, offsets, 1)
    residuals = offsets - (slope * times + intercept)
    # Standard error of a least-squares slope; needs n > 2 degrees of freedom.
    residual_rms = float(np.sqrt((residuals ** 2).sum() / (count - 2)))
    spread = float(((times - times.mean()) ** 2).sum())
    stderr = residual_rms / np.sqrt(spread) if spread > 0 else float("inf")

    return {
        "drift_slope_s_per_s": float(slope),
        "drift_stderr_s_per_s": float(stderr),
        "drift_per_hour_s": float(slope * 3600),
        "drift_ci95_per_hour_s": float(1.96 * stderr * 3600),
        "fit_residual_rms_s": residual_rms,
    }


def analyse(mic_path: Path, system_path: Path, interval_s: float) -> dict:
    for path in (mic_path, system_path):
        if not path.exists():
            raise DriftError(f"файл не знайдено: {path}")

    mic, mic_sr = load_mono(mic_path)
    system, sys_sr = load_mono(system_path)
    if mic_sr != sys_sr:
        raise DriftError(f"різна частота дискретизації: mic={mic_sr}, system={sys_sr}")

    sample_rate = mic_sr
    mic_env = envelope(mic, sample_rate)
    sys_env = envelope(system, sample_rate)

    mic_peaks = detect_clicks(mic_env, sample_rate, interval_s * 0.5)
    sys_peaks = detect_clicks(sys_env, sample_rate, interval_s * 0.5)
    pairs = pair_clicks(mic_peaks, sys_peaks, sample_rate)

    if not pairs:
        raise DriftError(
            "не знайдено жодної пари кліків "
            f"(mic: {mic_peaks.size}, system: {sys_peaks.size}) — перевірте тестовий стенд"
        )

    offsets = np.array([p[2] for p in pairs])
    times = np.array([p[0] for p in pairs])
    segment = int(round(XCORR_SEGMENT_S * sample_rate))

    return {
        **fit_drift(times, offsets),
        "sample_rate": sample_rate,
        "mic_samples": int(mic.size),
        "system_samples": int(system.size),
        "mic_duration_s": mic.size / sample_rate,
        "system_duration_s": system.size / sample_rate,
        "length_diff_s": (system.size - mic.size) / sample_rate,
        "clicks_mic": int(mic_peaks.size),
        "clicks_system": int(sys_peaks.size),
        "pairs": pairs,
        "offset_first_s": float(offsets[0]),
        "offset_last_s": float(offsets[-1]),
        "offset_max_abs_s": float(np.max(np.abs(offsets))),
        "offset_mean_s": float(np.mean(offsets)),
        "drift_s": float(offsets[-1] - offsets[0]),
        "xcorr_head_s": xcorr_lag_seconds(
            sys_env[:segment], mic_env[:segment], sample_rate, MATCH_WINDOW_S
        ),
        "xcorr_tail_s": xcorr_lag_seconds(
            sys_env[-segment:], mic_env[-segment:], sample_rate, MATCH_WINDOW_S
        ),
    }


def drift_phrase(result: dict) -> str:
    """One sentence a reviewer can trust: the estimate, its error bar, its verdict."""
    per_hour = result["drift_per_hour_s"]
    if per_hour is None:
        return "н/д (замало кліків для регресії — потрібно ≥3)"
    ci = result["drift_ci95_per_hour_s"]
    text = f"{per_hour * 1000:+.1f} мс/год (95% ДІ ±{ci * 1000:.1f})"
    if abs(per_hour) <= ci:
        text += " — невідрізнимий від нуля"
    return text


def format_report(result: dict, threshold_s: float, mic_path: Path, system_path: Path) -> str:
    ms = lambda value: "н/д" if value is None else f"{value * 1000:+.1f} мс"  # noqa: E731

    lines = [
        f"Файли:            {mic_path.name} / {system_path.name}",
        f"Частота:          {result['sample_rate']} Гц",
        f"Тривалість mic:   {result['mic_duration_s']:.3f} с ({result['mic_samples']} семплів)",
        f"Тривалість system:{result['system_duration_s']:.3f} с ({result['system_samples']} семплів)",
        f"Різниця довжин:   {result['length_diff_s'] * 1000:+.1f} мс",
        f"Кліків знайдено:  mic={result['clicks_mic']}, system={result['clicks_system']}, пар={len(result['pairs'])}",
        "",
        f"Зсув на початку:  {ms(result['offset_first_s'])}",
        f"Зсув у кінці:     {ms(result['offset_last_s'])}",
        f"Середній зсув:    {ms(result['offset_mean_s'])}",
        f"МАКСИМУМ |зсув|:  {result['offset_max_abs_s'] * 1000:.1f} мс",
        "",
        f"ДРЕЙФ (регресія): {drift_phrase(result)}",
        f"  наївно (кінець-початок): {ms(result['drift_s'])} — оцінка по двох точках, шумна",
        f"  залишковий шум:  {'н/д' if result['fit_residual_rms_s'] is None else f'{result['fit_residual_rms_s'] * 1000:.2f} мс RMS'}",
        "",
        f"Крос-кореляція (перші {XCORR_SEGMENT_S:g} с):  {ms(result['xcorr_head_s'])}",
        f"Крос-кореляція (останні {XCORR_SEGMENT_S:g} с): {ms(result['xcorr_tail_s'])}",
        "",
        f"Поріг приймання:  {threshold_s * 1000:.0f} мс",
    ]
    passed = result["offset_max_abs_s"] <= threshold_s
    lines.append("РЕЗУЛЬТАТ: ✅ ПРОЙДЕНО" if passed else "РЕЗУЛЬТАТ: ❌ НЕ ПРОЙДЕНО")
    return "\n".join(lines)


def format_markdown(result: dict, threshold_s: float, mic_path: Path, system_path: Path) -> str:
    passed = result["offset_max_abs_s"] <= threshold_s
    rows = "\n".join(
        f"| {i + 1} | {mt:.3f} | {st:.3f} | {off * 1000:+.1f} |"
        for i, (mt, st, off) in enumerate(result["pairs"])
    )
    return f"""# Звіт про розсинхрон каналів (drift-check)

**Файли:** `{mic_path}` / `{system_path}`
**Частота:** {result['sample_rate']} Гц
**Поріг ТЗ:** {threshold_s * 1000:.0f} мс

| Показник | Значення |
|---|---|
| Тривалість `mic` | {result['mic_duration_s']:.3f} с ({result['mic_samples']} семплів) |
| Тривалість `system` | {result['system_duration_s']:.3f} с ({result['system_samples']} семплів) |
| Різниця довжин | {result['length_diff_s'] * 1000:+.1f} мс |
| Зсув на початку | {result['offset_first_s'] * 1000:+.1f} мс |
| Зсув у кінці | {result['offset_last_s'] * 1000:+.1f} мс |
| **Максимум \\|зсув\\|** | **{result['offset_max_abs_s'] * 1000:.1f} мс** |
| **Дрейф (регресія по всіх кліках)** | **{drift_phrase(result)}** |
| Дрейф наївно (кінець − початок) | {result['drift_s'] * 1000:+.1f} мс — оцінка по двох точках |
| Залишковий шум вимірювання | {'н/д' if result['fit_residual_rms_s'] is None else f"{result['fit_residual_rms_s'] * 1000:.2f} мс RMS"} |
| Результат | {'✅ ПРОЙДЕНО' if passed else '❌ НЕ ПРОЙДЕНО'} |

> Постійний зсув між каналами — це різниця латентності двох трактів, а не дрейф:
> вона не накопичується. Критерій ТЗ №1 стосується саме нахилу — того, наскільки
> зсув **змінюється** за годину.

## Покліковий розклад

| # | mic, с | system, с | зсув, мс |
|---|---|---|---|
{rows}
"""


def main() -> int:
    p = argparse.ArgumentParser(description="Measure mic/system channel drift")
    p.add_argument("session_dir", nargs="?", type=Path, help="session directory with mic.caf and system.caf")
    p.add_argument("--mic", type=Path, help="explicit path to the mic track")
    p.add_argument("--system", type=Path, help="explicit path to the system track")
    p.add_argument("--threshold", type=float, default=0.3, help="acceptance threshold, seconds")
    p.add_argument("--interval", type=float, default=5.0, help="expected seconds between clicks")
    p.add_argument("--markdown", type=Path, help="also write a Markdown report to this path")
    args = p.parse_args()

    if args.mic and args.system:
        mic_path, system_path = args.mic, args.system
    elif args.session_dir:
        mic_path = args.session_dir / "mic.caf"
        system_path = args.session_dir / "system.caf"
    else:
        p.error("вкажіть теку сесії або обидва шляхи --mic/--system")

    try:
        result = analyse(mic_path, system_path, args.interval)
    except DriftError as exc:
        print(f"ПОМИЛКА: {exc}", file=sys.stderr)
        return 2

    print(format_report(result, args.threshold, mic_path, system_path))

    if args.markdown:
        args.markdown.parent.mkdir(parents=True, exist_ok=True)
        args.markdown.write_text(format_markdown(result, args.threshold, mic_path, system_path), encoding="utf-8")
        print(f"\nMarkdown-звіт: {args.markdown}")

    return 0 if result["offset_max_abs_s"] <= args.threshold else 1


if __name__ == "__main__":
    sys.exit(main())
