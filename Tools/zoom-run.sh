#!/bin/zsh
# ТЗ criteria #1 and #3: a real meeting, recorded into two separate tracks.
#
#   Tools/zoom-run.sh [хвилин]        # default 60
#
# The problem this run has to solve first: the bench Mac has no microphone, so the
# advisor's side would be silent and "voices land in different files" could not be
# demonstrated at all. Instead the advisor is synthesised — `say -v Lesya` writes a
# Ukrainian monologue, `play-to-device` pushes it straight into BlackHole, and Zoom
# is configured to use BlackHole as its microphone. That single feed does double
# duty: the client hears the advisor over the call, and our microphone track records
# the very same voice through the loopback.
#
# Channel separation then follows from the routing itself, with nothing shared:
#
#   advisor  → say → BlackHole → Zoom mic  → heard by the client
#                             ↘ mic.caf    (loopback input)
#   client   → Zoom → speakers → tap       → system.caf
#
# Zoom never plays the advisor back, so neither voice can leak into the other track.
#
# Start with `open` / double-click — TCC grants belong to Terminal.
set -euo pipefail

cd "$(dirname "$0")/.."

MINUTES="${1:-60}"
PLATFORM="${PLATFORM:-Zoom}"
SECONDS_TO_RECORD=$((MINUTES * 60))
OUT_DIR="/tmp/stlth-zoom-run"
PYTHON=".venv/bin/python"
# Each run gets its own directory. An earlier version reused one path and wiped it
# on start, which quietly destroyed the recording of a full hour of Zoom the moment
# the next run began. Acceptance material is expensive to produce; it must not be
# the thing a rerun overwrites.
RUN_DIR="$OUT_DIR/$(date '+%Y%m%d-%H%M%S')"

VOICE="$RUN_DIR/advisor.wav"

mkdir -p "$RUN_DIR"

echo "════════════════════════════════════════════════════════"
echo "  Приймальний прогін у $PLATFORM — $MINUTES хв"
echo "════════════════════════════════════════════════════════"
echo ""
echo "ПЕРЕД стартом переконайся, що:"
echo "  • ти вже в мітингу з Windows як «клієнт»;"
echo "  • на маку в $PLATFORM: мікрофон = BlackHole 2ch (або «за замовчуванням»),"
echo "                          динамік  = Mac mini Speakers."
echo ""
if [[ -z "${AUTO_START:-}" ]]; then
  read "?Натисни Enter, коли готовий… "
fi

echo ""
echo "==> Готую стенд"
make recorder-cli >/dev/null
SwitchAudioSource -t input -s "BlackHole 2ch" >/dev/null
SwitchAudioSource -t output -s "Mac mini Speakers" >/dev/null
echo "    вхід:  $(SwitchAudioSource -c -t input)"
echo "    вихід: $(SwitchAudioSource -c -t output)"

echo "==> Синтезую монолог радника"
SCRIPT_TEXT="Доброго дня. Мене звати Володимир, я ваш фінансовий радник. \
Сьогодні ми обговоримо структуру вашого портфеля та цілі на найближчі три роки. \
Почнімо з того, який рівень ризику для вас комфортний. \
Далі подивимось на розподіл між акціями та облігаціями. \
Наприкінці зустрічі я підсумую домовленості та надішлю вам протокол."

say -v Lesya -o "$RUN_DIR/advisor.aiff" "$SCRIPT_TEXT"
# Loop the monologue for the whole meeting: the microphone track has to carry speech
# throughout, not fall silent after the first minute.
afconvert -f WAVE -d LEI16@48000 -c 2 "$RUN_DIR/advisor.aiff" "$RUN_DIR/advisor-one.wav" >/dev/null
$PYTHON - "$RUN_DIR/advisor-one.wav" "$VOICE" "$SECONDS_TO_RECORD" <<'PY'
import sys, numpy as np, soundfile as sf
src, dst, total = sys.argv[1], sys.argv[2], int(sys.argv[3])
data, rate = sf.read(src)
if data.ndim == 1:
    data = np.column_stack([data, data])
# Three seconds of silence between repeats so the track sounds like speech with
# pauses rather than an unbroken drone — closer to how a person actually talks.
gap = np.zeros((3 * rate, data.shape[1]))
block = np.vstack([data, gap])
repeats = int(np.ceil((total + 60) * rate / len(block)))
sf.write(dst, np.vstack([block] * repeats)[: (total + 60) * rate], rate)
print(f"    монолог на {(total + 60) / 60:.0f} хв")
PY

echo ""
echo "==> Старт. Говори з Windows як клієнт — не мовчи довше хвилини."
echo "    Мак у цей час «говорить» синтезованим голосом радника."
echo ""

./build/play-to-device "$VOICE" "BlackHole" $((SECONDS_TO_RECORD + 30)) >/dev/null 2>&1 &
VOICE_PID=$!
trap 'kill $VOICE_PID 2>/dev/null || true' EXIT

# The player is excluded from the tap: without that its output — the advisor's
# synthesised voice — would be captured into the system track too, and the two
# channels would carry the same voice.
caffeinate -s ./build/recorder-cli record "$SECONDS_TO_RECORD" --dir "$RUN_DIR/session" \
  --exclude-pid "$VOICE_PID"
kill $VOICE_PID 2>/dev/null || true

SESSION_DIR=$(find "$RUN_DIR/session" -maxdepth 1 -mindepth 1 -type d | head -1)

echo ""
echo "==> Розбір: чи справді голоси в різних файлах"
$PYTHON - "$SESSION_DIR" <<'PY'
import json
import sys
from pathlib import Path
import numpy as np
import soundfile as sf

session = Path(sys.argv[1])
mic, rate = sf.read(session / "mic.caf")
system, _ = sf.read(session / "system.caf")
mic = np.atleast_2d(mic.T).mean(axis=0)
system = np.atleast_2d(system.T).mean(axis=0)
ok = True

print(f"    mic.caf:    {len(mic)} семплів, пік {np.abs(mic).max():.4f}, "
      f"RMS {np.sqrt((mic ** 2).mean()):.5f}")
print(f"    system.caf: {len(system)} семплів, пік {np.abs(system).max():.4f}, "
      f"RMS {np.sqrt((system ** 2).mean()):.5f}")

if len(mic) != len(system):
    print("    ❌ треки різної довжини")
    ok = False
else:
    print("    ✅ треки однакової довжини")

for name, track in (("радника (mic)", mic), ("клієнта (system)", system)):
    if np.sqrt((track ** 2).mean()) < 1e-4:
        print(f"    ❌ канал {name} практично порожній")
        ok = False
    else:
        print(f"    ✅ канал {name} містить голос")

# Channel separation: if one voice bled into the other track, the two envelopes
# would rise and fall together. Independent speakers should not correlate.
def envelope(x, rate, window=0.05):
    n = int(rate * window)
    trimmed = x[: len(x) // n * n].reshape(-1, n)
    return np.abs(trimmed).mean(axis=1)

a, b = envelope(mic, rate), envelope(system, rate)
size = min(len(a), len(b))
corr = float(np.corrcoef(a[:size], b[:size])[0, 1]) if size > 10 else 0.0
print(f"    кореляція огинаючих каналів: {corr:+.3f}")
if abs(corr) > 0.5:
    print("    ⚠️  канали підозріло схожі — можливий витік одного голосу в інший")
else:
    print("    ✅ канали незалежні — голоси розділені")

meta = json.loads((session / "meta.json").read_text())
print(f"    режим захоплення: {meta.get('captureMode')}, "
      f"змін пристроїв: {len(meta.get('deviceChanges', []))}")
print("")
print("    " + ("✅ ПРОГІН ПРИДАТНИЙ ДЛЯ ПРИЙМАЛЬНОЇ МАТРИЦІ"
               if ok else "❌ ПРОГІН НЕВДАЛИЙ — дивись зауваження вище"))
print("")
print(f"    Файли: {session}")
print("    Послухай вибірково обидва файли перед тим, як зараховувати критерій.")
PY
