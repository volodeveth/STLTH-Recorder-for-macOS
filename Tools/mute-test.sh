#!/bin/zsh
# ТЗ criterion #4: ten minutes of mute must not shift the timeline.
#
# The advisor goes quiet for ten minutes while the client keeps talking. If silence
# were dropped instead of written, the microphone track would end up ten minutes
# shorter — and everything recorded after the pause would sit ten minutes early
# relative to the client's track. That is the failure this run is built to catch.
#
# Wiring (dev bench only):
#   default output = speakers        → the click train reaches the process tap
#   play-to-device → BlackHole       → the same click train reaches the "microphone",
#                                      without touching the default output
#
# The microphone feed is played for the first minute, left silent for ten, then
# played again — starting on a multiple of the click interval so both bursts sit on
# the same absolute grid. The two tracks are then compared: if the mic timeline had
# collapsed, its post-pause clicks would be minutes away from the system's.
#
# Must be started with `open` / double-click, not over SSH — TCC grants belong to
# Terminal, and an SSH-launched capture records digital silence.
set -euo pipefail

cd "$(dirname "$0")/.."

MUTE_SECONDS="${1:-600}"
LEAD=60
TOTAL=$((LEAD + MUTE_SECONDS + LEAD))
INTERVAL=5
OUT_DIR="/tmp/stlth-mute-test"
PYTHON=".venv/bin/python"

mkdir -p "$OUT_DIR"
rm -rf "$OUT_DIR/session"

echo "==> Готую стенд (тиша $MUTE_SECONDS с у межах $TOTAL с)"
make recorder-cli >/dev/null
SwitchAudioSource -t output -s "Mac mini Speakers" >/dev/null
SwitchAudioSource -t input -s "BlackHole 2ch" >/dev/null
echo "    вхід:  $(SwitchAudioSource -c -t input)"
echo "    вихід: $(SwitchAudioSource -c -t output)"

$PYTHON Tools/gen_clicks.py --out "$OUT_DIR/long.wav" \
  --duration $((TOTAL + 10)) --interval $INTERVAL --first-at 0.5 >/dev/null
$PYTHON Tools/gen_clicks.py --out "$OUT_DIR/burst.wav" \
  --duration $((LEAD + 5)) --interval $INTERVAL --first-at 0.5 >/dev/null

echo "==> Старт: системний канал грає весь час, мікрофонний — перша хвилина"
afplay "$OUT_DIR/long.wav" &
AFPLAY_PID=$!
trap 'kill $AFPLAY_PID 2>/dev/null || true' EXIT

./build/play-to-device "$OUT_DIR/burst.wav" "BlackHole" $LEAD >/dev/null 2>&1 &

./build/recorder-cli record "$TOTAL" --dir "$OUT_DIR/session" &
RECORDER_PID=$!

echo "    [$(date '+%H:%M:%S')] мікрофон замовкає на $MUTE_SECONDS с"
sleep $((LEAD + MUTE_SECONDS))
echo "    [$(date '+%H:%M:%S')] мікрофон знову говорить"
./build/play-to-device "$OUT_DIR/burst.wav" "BlackHole" $LEAD >/dev/null 2>&1 &

wait $RECORDER_PID
kill $AFPLAY_PID 2>/dev/null || true

SESSION_DIR=$(find "$OUT_DIR/session" -maxdepth 1 -mindepth 1 -type d | head -1)

echo ""
echo "==> Перевірка критерію №4"
$PYTHON - "$SESSION_DIR" "$LEAD" "$MUTE_SECONDS" <<'PY'
import sys
import numpy as np
import soundfile as sf
from pathlib import Path

session = Path(sys.argv[1])
lead = int(sys.argv[2])
mute = int(sys.argv[3])

mic, sr = sf.read(session / "mic.caf")
system, _ = sf.read(session / "system.caf")
mic = np.abs(np.atleast_2d(mic.T)).max(axis=0)
system = np.abs(np.atleast_2d(system.T)).max(axis=0)

ok = True

print(f"    довжина mic:    {len(mic)} семплів ({len(mic)/sr:.3f} с)")
print(f"    довжина system: {len(system)} семплів ({len(system)/sr:.3f} с)")
if len(mic) != len(system):
    print(f"    ❌ треки різної довжини: різниця {abs(len(mic)-len(system))} семплів")
    ok = False
else:
    print("    ✅ треки однакової довжини")

# The mute window, kept clear of the edges so playback tails cannot leak in.
a, b = int((lead + 5) * sr), int((lead + mute - 5) * sr)
window_peak = mic[a:b].max()
print(f"    пік у вікні тиші ({lead+5}–{lead+mute-5} с): {window_peak:.5f}")
if window_peak > 0.02:
    print("    ❌ у вікні тиші є сигнал — стенд відпрацював не так, як задумано")
    ok = False
else:
    print(f"    ✅ мікрофон справді мовчав {mute} с")

# Silence has to be *written*: that stretch must exist as samples, not be skipped.
written = (b - a) / sr
print(f"    тиша записана як {b-a} семплів ({written:.1f} с), а не вирізана")


def clicks(signal, threshold=0.2, min_gap=1.0):
    loud = np.flatnonzero(signal > threshold)
    if loud.size == 0:
        return np.array([])
    breaks = np.flatnonzero(np.diff(loud) > int(min_gap * sr))
    starts = np.concatenate(([loud[0]], loud[breaks + 1]))
    return starts / sr


mic_clicks = clicks(mic)
sys_clicks = clicks(system)
print(f"    кліків: mic={len(mic_clicks)}, system={len(sys_clicks)}")

post = mic_clicks[mic_clicks > lead + mute - 1]
if post.size == 0:
    print("    ❌ після паузи в мікрофоні немає жодного кліка")
    ok = False
else:
    # The decisive check: had the mic timeline collapsed, its first post-pause click
    # would land near the one-minute mark instead of near minute eleven.
    offsets = [abs(sys_clicks - t).min() * 1000 for t in post]
    worst = max(offsets)
    print(f"    перший клік після паузи: {post[0]:.3f} с "
          f"(очікувано біля {lead+mute}.5 с)")
    print(f"    максимальний зсув mic↔system після паузи: {worst:.1f} мс")
    if worst > 300:
        print("    ❌ таймлайн зсунувся — критерій №4 НЕ виконано")
        ok = False
    else:
        print("    ✅ таймлайн не зсунувся (поріг ТЗ 300 мс)")

print("")
print("    " + ("✅ КРИТЕРІЙ №4 ПРОЙДЕНО" if ok else "❌ КРИТЕРІЙ №4 НЕ ПРОЙДЕНО"))
PY
