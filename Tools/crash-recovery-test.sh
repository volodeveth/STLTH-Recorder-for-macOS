#!/bin/zsh
# ТЗ criterion #6 under the worst case: the app dies mid-recording.
#
# `kill -9` gives the process no chance to close its files, so this is where a
# recording either survives honestly or turns into a corrupt session. Two things
# have to hold afterwards:
#
#   * the session is reconciled — status "interrupted" with the real duration,
#     not left claiming to be still recording;
#   * both tracks open in a reader that is NOT Apple's. While a CAF is being
#     written its data chunk carries size -1, and AVAudioFile/QuickTime tolerate
#     that while ffmpeg and libsndfile refuse the file outright — so checking with
#     QuickTime alone would hide the problem. CAFRepair rewrites the real size on
#     recovery; soundfile (libsndfile) is what proves it worked.
#
# Run with `open` / double-click: an SSH-launched capture records digital silence,
# and this run wants real samples in the file.
set -euo pipefail

cd "$(dirname "$0")/.."

RECORD_FOR="${1:-60}"
KILL_AFTER="${2:-15}"
OUT_DIR="/tmp/stlth-crash-test"
PYTHON=".venv/bin/python"

mkdir -p "$OUT_DIR"
rm -rf "$OUT_DIR/session"

echo "==> Готую стенд"
make recorder-cli >/dev/null
SwitchAudioSource -t output -s "Mac mini Speakers" >/dev/null
$PYTHON Tools/gen_clicks.py --out "$OUT_DIR/clicks.wav" \
  --duration $((RECORD_FOR + 10)) --interval 2 >/dev/null

echo "==> Пишу $RECORD_FOR с, вбиваю через $KILL_AFTER с"
afplay "$OUT_DIR/clicks.wav" &
AFPLAY_PID=$!
trap 'kill $AFPLAY_PID 2>/dev/null || true' EXIT

./build/recorder-cli record "$RECORD_FOR" --dir "$OUT_DIR/session" &
RECORDER_PID=$!

sleep "$KILL_AFTER"
echo "    [$(date '+%H:%M:%S')] kill -9 $RECORDER_PID"
kill -9 $RECORDER_PID 2>/dev/null || true
wait $RECORDER_PID 2>/dev/null || true
kill $AFPLAY_PID 2>/dev/null || true
sleep 1

SESSION_DIR=$(find "$OUT_DIR/session" -maxdepth 1 -mindepth 1 -type d | head -1)
echo ""
echo "==> Стан ДО відновлення"
$PYTHON -c "
import json,sys
m=json.load(open('$SESSION_DIR/meta.json'))
print(f\"    статус: {m['status']}, тривалість: {m['durationMs']} мс\")
"

echo ""
echo "==> Запускаю відновлення (як це робить застосунок при старті)"
./build/recorder-cli recover "$OUT_DIR/session"

echo ""
echo "==> Перевірка"
$PYTHON - "$SESSION_DIR" "$KILL_AFTER" <<'PY'
import json, sys
from pathlib import Path
import soundfile as sf

session = Path(sys.argv[1])
killed_after = int(sys.argv[2])
ok = True

meta = json.loads((session / "meta.json").read_text())
print(f"    статус: {meta['status']}")
if meta["status"] != "interrupted":
    print("    ❌ сесія не позначена як перервана")
    ok = False
else:
    print("    ✅ сесія позначена як перервана")

duration = meta["durationMs"] / 1000
print(f"    тривалість у meta: {duration:.3f} с (вбито на {killed_after} с)")
if not (killed_after - 3 <= duration <= killed_after + 3):
    print("    ❌ тривалість не збігається з моментом убивства")
    ok = False
else:
    print("    ✅ тривалість відповідає реальності")

for name, expected_channels in (("mic.caf", 1), ("system.caf", 2)):
    path = session / name
    try:
        # libsndfile, deliberately: it rejects the unrepaired data chunk that
        # Apple's readers quietly tolerate.
        data, rate = sf.read(path)
        frames = len(data)
        channels = 1 if data.ndim == 1 else data.shape[1]
        print(f"    ✅ {name}: читається libsndfile — {frames} семплів, "
              f"{channels} кан., {rate} Гц")
        if channels != expected_channels:
            print(f"    ❌ {name}: очікували {expected_channels} канал(и)")
            ok = False
        if abs(frames / rate - duration) > 3:
            print(f"    ❌ {name}: довжина не збігається з meta")
            ok = False
    except Exception as exc:
        print(f"    ❌ {name}: libsndfile не читає — {exc}")
        ok = False

peak = 0.0
try:
    import numpy as np
    data, _ = sf.read(session / "system.caf")
    peak = float(np.abs(data).max())
except Exception:
    pass
print(f"    пік у системному каналі: {peak:.4f}")
if peak < 0.01:
    print("    ⚠️  аудіо порожнє — запускали по SSH? потрібен запуск із Terminal")

print("")
print("    " + ("✅ ВІДНОВЛЕННЯ ПРАЦЮЄ" if ok else "❌ ВІДНОВЛЕННЯ ЗЛАМАНЕ"))
PY
