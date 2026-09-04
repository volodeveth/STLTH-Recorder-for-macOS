#!/usr/bin/env python3
"""Self-test for the drift toolchain on synthetic audio — no Mac audio hardware needed.

Builds mic/system pairs with a known artificial offset and asserts that
drift_check.py reports that offset and exits with the right status:

    offset 150 ms  -> reported ~150 ms, exit 0 (below the 300 ms threshold)
    offset 400 ms  -> reported ~400 ms, exit 1 (above the threshold)
    offset 0 ms    -> reported ~0 ms,   exit 0

Usage:
    python3 Tools/selftest_drift.py
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
import soundfile as sf

sys.path.insert(0, str(Path(__file__).resolve().parent))

from gen_clicks import generate  # noqa: E402

SAMPLE_RATE = 48000
DURATION_S = 60.0
INTERVAL_S = 5.0
TOLERANCE_MS = 5.0
NOISE_AMPLITUDE = 0.002  # a little noise so the detector is not tested on a clean signal


def build_pair(directory: Path, offset_s: float, rng: np.random.Generator) -> None:
    """Write mic.caf/system.caf where the system track lags the mic track by offset_s."""
    base = generate(DURATION_S, INTERVAL_S, SAMPLE_RATE, first_at_s=1.0)
    shift = int(round(offset_s * SAMPLE_RATE))

    mic = base.copy()
    system = np.roll(base, shift)
    if shift > 0:
        system[:shift] = 0.0
    elif shift < 0:
        system[shift:] = 0.0

    mic += rng.normal(0.0, NOISE_AMPLITUDE, mic.size)
    system += rng.normal(0.0, NOISE_AMPLITUDE, system.size)

    sf.write(str(directory / "mic.caf"), mic, SAMPLE_RATE, format="CAF", subtype="PCM_16")
    # system track is stereo in the real product — keep the self-test faithful to that
    sf.write(
        str(directory / "system.caf"),
        np.column_stack([system, system]),
        SAMPLE_RATE,
        format="CAF",
        subtype="PCM_16",
    )


def run_case(offset_ms: float, expected_exit: int, rng: np.random.Generator) -> bool:
    with tempfile.TemporaryDirectory() as tmp:
        directory = Path(tmp)
        build_pair(directory, offset_ms / 1000.0, rng)

        proc = subprocess.run(
            [sys.executable, str(Path(__file__).resolve().parent / "drift_check.py"), str(directory)],
            capture_output=True,
            text=True,
        )
        output = proc.stdout

        measured: float | None = None
        for line in output.splitlines():
            if line.startswith("МАКСИМУМ |зсув|:"):
                measured = float(line.split(":")[1].strip().split()[0])

        ok = True
        if measured is None:
            print(f"  ✗ не вдалося розпарсити вивід:\n{output}\n{proc.stderr}")
            return False
        if abs(measured - abs(offset_ms)) > TOLERANCE_MS:
            print(f"  ✗ зсув {offset_ms:g} мс: виміряно {measured:.1f} мс (очікували ±{TOLERANCE_MS:g} мс)")
            ok = False
        if proc.returncode != expected_exit:
            print(f"  ✗ зсув {offset_ms:g} мс: exit={proc.returncode}, очікували {expected_exit}")
            ok = False
        if ok:
            print(f"  ✓ зсув {offset_ms:g} мс → виміряно {measured:.1f} мс, exit={proc.returncode}")
        return ok


def main() -> int:
    rng = np.random.default_rng(20260806)
    cases = [(0.0, 0), (150.0, 0), (400.0, 1), (-150.0, 0)]

    print("Самоперевірка drift-інструментів на синтетичних файлах:")
    results = [run_case(offset, expected, rng) for offset, expected in cases]

    if all(results):
        print(f"\nУСПІХ: {len(results)}/{len(results)} кейсів пройдено")
        return 0
    print(f"\nПРОВАЛ: {sum(results)}/{len(results)} кейсів пройдено")
    return 1


if __name__ == "__main__":
    sys.exit(main())
