#!/bin/zsh
# Inter-channel drift run: one signal, both tracks, one number at the end.
#
#   Tools/twochannel-run.sh [seconds]      # default 70
#
# MUST BE RUN FROM THE TERMINAL ON THE VNC SCREEN, not over SSH. The TCC grants for
# microphone and system-audio capture belong to Terminal; a process started over SSH
# gets IO callbacks but silent buffers, so the drift check would find no clicks.
#
# Bench wiring (dev-only — the product never touches virtual devices, ТЗ F-2):
#   default output = STLTH Dev Multi-Output (speakers + BlackHole)
#   default input  = BlackHole 2ch
# One click train therefore reaches the process tap (it is being played by the system)
# AND the loopback "microphone" at the same instant — so any offset between the two
# tracks is real drift, not a difference in source.
set -euo pipefail

cd "$(dirname "$0")/.."

SECONDS_TO_RECORD="${1:-70}"
OUT_DIR="${2:-/tmp/stlth-twochannel}"
CLICKS="$OUT_DIR/clicks.wav"
PYTHON=".venv/bin/python"

mkdir -p "$OUT_DIR"

echo "==> 1/5 Збираю recorder-cli"
make recorder-cli >/dev/null

echo "==> 2/5 Налаштовую стенд"
./build/make-multiout create
SwitchAudioSource -t input -s "BlackHole 2ch" >/dev/null
echo "    вхід:  $(SwitchAudioSource -c -t input)"
echo "    вихід: $(SwitchAudioSource -c -t output)"

echo "==> 3/5 Генерую клік-трек на $SECONDS_TO_RECORD с"
$PYTHON Tools/gen_clicks.py --out "$CLICKS" \
  --duration $((SECONDS_TO_RECORD + 10)) --interval 5

echo "==> 4/5 Пишу $SECONDS_TO_RECORD с (кліки грають через Multi-Output)"
SESSION_ROOT="$OUT_DIR/session"
rm -rf "$SESSION_ROOT"
afplay "$CLICKS" &
AFPLAY_PID=$!
trap 'kill $AFPLAY_PID 2>/dev/null || true' EXIT
sleep 1
./build/recorder-cli record "$SECONDS_TO_RECORD" --dir "$SESSION_ROOT"
kill $AFPLAY_PID 2>/dev/null || true

SESSION_DIR=$(find "$SESSION_ROOT" -maxdepth 1 -mindepth 1 -type d | head -1)

echo "==> 5/5 Міряю міжканальний дрейф"
$PYTHON Tools/drift_check.py "$SESSION_DIR" --interval 5 \
  --markdown "$OUT_DIR/drift-twochannel.md"

echo ""
echo "Сесія: $SESSION_DIR"
echo "Звіт:  $OUT_DIR/drift-twochannel.md"
