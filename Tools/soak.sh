#!/bin/zsh
# Overnight soak: a long unattended recording that has to neither leak memory nor
# drift, and has to come back as a file that still opens.
#
#   Tools/soak.sh 7200        # two hours
#
# Start it with `open` / double-click, not over SSH: TCC grants belong to Terminal,
# and an SSH-launched capture writes digital silence — a soak that records nothing
# proves nothing.
set -euo pipefail

cd "$(dirname "$0")/.."

SECONDS_TO_RECORD="${1:-7200}"
OUT_DIR="${2:-/tmp/stlth-soak}"
LOG="$OUT_DIR/soak.log"
SIGNAL="$OUT_DIR/signal.wav"
PYTHON=".venv/bin/python"

mkdir -p "$OUT_DIR"
rm -rf "$OUT_DIR/session"
: > "$LOG"

echo "==> Збираю recorder-cli" | tee -a "$LOG"
make recorder-cli >/dev/null

# A process tap does not start delivering until something plays, and a soak run in
# silence would measure nothing at all. The click train doubles as the drift
# reference, so the same run answers both questions.
echo "==> Готую сигнал на $SECONDS_TO_RECORD с" | tee -a "$LOG"
$PYTHON Tools/gen_clicks.py --out "$SIGNAL" \
  --duration $((SECONDS_TO_RECORD + 60)) --interval 5 >/dev/null

SwitchAudioSource -t output -s "Mac mini Speakers" >/dev/null 2>&1 || true

echo "==> Soak: $SECONDS_TO_RECORD с у $OUT_DIR (старт $(date '+%H:%M:%S'))" | tee -a "$LOG"

afplay "$SIGNAL" &
AFPLAY_PID=$!
trap 'kill $AFPLAY_PID 2>/dev/null || true' EXIT

caffeinate -s ./build/recorder-cli record "$SECONDS_TO_RECORD" --dir "$OUT_DIR/session" 2>&1 \
  | tee -a "$LOG" &
WRAPPER_PID=$!

# Sample the recorder's own footprint, not caffeinate's — caffeinate is the parent
# here, and its RSS stays flat no matter what the recorder does, which would make a
# leak invisible.
(
  sleep 5
  while kill -0 $WRAPPER_PID 2>/dev/null; do
    CLI_PID=$(pgrep -f 'recorder-cli record' | head -1)
    if [[ -n "$CLI_PID" ]]; then
      echo "[$(date '+%H:%M:%S')] RSS $(ps -o rss= -p "$CLI_PID" | tr -d ' ') KB" >> "$LOG"
    fi
    sleep 300
  done
) &

wait $WRAPPER_PID
kill $AFPLAY_PID 2>/dev/null || true

echo "" | tee -a "$LOG"
echo "==> Пам'ять по ходу запису" | tee -a "$LOG"
grep RSS "$LOG" | tail -30

FIRST_RSS=$(grep RSS "$LOG" | head -1 | awk '{print $3}')
LAST_RSS=$(grep RSS "$LOG" | tail -1 | awk '{print $3}')
if [[ -n "$FIRST_RSS" && -n "$LAST_RSS" ]]; then
  GROWTH=$(( LAST_RSS - FIRST_RSS ))
  echo "    приріст за прогін: ${GROWTH} KB (${FIRST_RSS} → ${LAST_RSS})" | tee -a "$LOG"
fi

SESSION_DIR=$(find "$OUT_DIR/session" -maxdepth 1 -mindepth 1 -type d | head -1)
if [[ -n "$SESSION_DIR" ]]; then
  echo "" | tee -a "$LOG"
  echo "==> drift-check" | tee -a "$LOG"
  # Deliberately NOT docs/notes/drift-report.md: that file is written by hand and
  # carries the reasoning behind the numbers. A soak writes its own artefact.
  mkdir -p docs/notes/evidence
  $PYTHON Tools/drift_check.py "$SESSION_DIR" --interval 5 \
    --markdown "docs/notes/evidence/soak-${SECONDS_TO_RECORD}s.md" 2>&1 | tee -a "$LOG" || true
fi

echo "" | tee -a "$LOG"
echo "==> Готово $(date '+%H:%M:%S')" | tee -a "$LOG"
