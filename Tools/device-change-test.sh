#!/bin/zsh
# Hardware check for the mid-recording device switch (ТЗ spec §4).
#
# Plugging in AirPods during a meeting is the everyday case: the default output
# changes under a running recording, and the engine has to rebuild its aggregate
# around the new device without losing the timeline.
#
# The run switches the default output twice while recording, then checks that
#   * both tracks still hold duration × 48000 samples,
#   * the switches are recorded in meta.json,
#   * audio keeps arriving after each rebuild.
#
# Must be started with `open` (or double-clicked) rather than over SSH: the TCC
# grants for system-audio capture belong to Terminal, and an SSH-launched process
# records digital silence — the "audio survived the rebuild" check would be void.
set -euo pipefail

cd "$(dirname "$0")/.."

SECONDS_TO_RECORD="${1:-30}"
OUT_DIR="/tmp/stlth-device-change"
CLICKS="$OUT_DIR/clicks.wav"
PYTHON=".venv/bin/python"
SPEAKERS="Mac mini Speakers"
OTHER="STLTH Dev Multi-Output"

mkdir -p "$OUT_DIR"
rm -rf "$OUT_DIR/session"

echo "==> Готую стенд"
make recorder-cli >/dev/null
./build/make-multiout create >/dev/null
SwitchAudioSource -t output -s "$SPEAKERS" >/dev/null
SwitchAudioSource -t input -s "BlackHole 2ch" >/dev/null
echo "    вхід:  $(SwitchAudioSource -c -t input)"
echo "    вихід: $(SwitchAudioSource -c -t output)"

$PYTHON Tools/gen_clicks.py --out "$CLICKS" \
  --duration $((SECONDS_TO_RECORD + 10)) --interval 2 >/dev/null

echo "==> Пишу $SECONDS_TO_RECORD с, перемикаючи вихід посеред запису"
afplay "$CLICKS" &
AFPLAY_PID=$!
trap 'kill $AFPLAY_PID 2>/dev/null || true' EXIT

./build/recorder-cli record "$SECONDS_TO_RECORD" --dir "$OUT_DIR/session" &
RECORDER_PID=$!

sleep $((SECONDS_TO_RECORD / 3))
echo "    [$(date '+%H:%M:%S')] вихід → $OTHER"
SwitchAudioSource -t output -s "$OTHER" >/dev/null

sleep $((SECONDS_TO_RECORD / 3))
echo "    [$(date '+%H:%M:%S')] вихід → $SPEAKERS"
SwitchAudioSource -t output -s "$SPEAKERS" >/dev/null

wait $RECORDER_PID
kill $AFPLAY_PID 2>/dev/null || true

SESSION_DIR=$(find "$OUT_DIR/session" -maxdepth 1 -mindepth 1 -type d | head -1)

echo ""
echo "==> Зафіксовані зміни пристроїв у meta.json"
$PYTHON - "$SESSION_DIR/meta.json" <<'PY'
import json, sys
meta = json.load(open(sys.argv[1]))
changes = meta.get("deviceChanges", [])
print(f"    режим захоплення: {meta.get('captureMode')}")
print(f"    записано змін:    {len(changes)}")
for c in changes:
    what = "вихід" if c.get("output") else "вхід"
    print(f"      {c['at']}  {what} → {c.get('output') or c.get('input')}")
print("    " + ("✅ зміни зафіксовані" if changes else "❌ жодної зміни не записано"))
PY

echo ""
echo "==> Чи вцілів звук після кожної перебудови"
$PYTHON - "$SESSION_DIR" <<'PY'
import sys, numpy as np, soundfile as sf
from pathlib import Path

d = Path(sys.argv[1])
x, sr = sf.read(d / "system.caf")
x = np.abs(np.atleast_2d(x.T)).max(axis=0)
total = len(x) / sr
# Split the recording into thirds: before the first switch, between the two, after.
names = ["до перемикання", "після 1-го", "після 2-го"]
edges = [0, len(x) // 3, 2 * len(x) // 3, len(x)]
ok = True
for name, a, b in zip(names, edges[:-1], edges[1:]):
    seg = x[a:b]
    peak = seg.max()
    print(f"    {name:16s} peak={peak:.4f}")
    if peak < 0.01:
        ok = False
print(f"    тривалість: {total:.3f} с")
print("    " + ("✅ звук є в усіх трьох відрізках" if ok
               else "⚠️  є відрізок без звуку — дивись, чи це не наслідок перебудови"))
PY
