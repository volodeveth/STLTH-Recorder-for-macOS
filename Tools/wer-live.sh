#!/bin/zsh
# Word error rate on a *human* voice arriving through a real call.
#
#   Tools/wer-live.sh [секунд]        # default 150
#
# Every quality figure so far came from a synthesised voice, which is easier to
# recognise than a person and therefore only bounds the answer from above. This run
# closes that gap: someone reads a known text into the call from the other machine,
# the client's channel records it, and the transcript is compared word by word
# against what was actually written.
#
# Only the client channel is measured — that is the one that travels over the
# network, and the one whose quality was never verified on real speech.
#
# Start with `open` / double-click: TCC grants belong to Terminal.
set -euo pipefail

cd "$(dirname "$0")/.."

SECONDS_TO_RECORD="${1:-150}"
OUT="/tmp/stlth-wer-live/$(date '+%H%M%S')"
REFERENCE="Tools/wer-reference.txt"
PYTHON=".venv/bin/python"

mkdir -p "$OUT"

clear
echo "════════════════════════════════════════════════════════"
echo "  Вимірювання якості на живому голосі"
echo "════════════════════════════════════════════════════════"
echo ""
echo "Що робити:"
echo "  • будь у дзвінку з Windows як клієнт;"
echo "  • читай текст із Tools/wer-reference.txt у звичайному темпі;"
echo "  • не виправляй себе — обмовки теж частина реальності;"
echo "  • якщо дочитаєш раніше — просто мовчи до кінця."
echo ""
echo "Запис триватиме $SECONDS_TO_RECORD с."
echo ""
read "?Натисни Enter, коли готовий читати… "

make recorder-cli >/dev/null
SwitchAudioSource -t output -s "Mac mini Speakers" >/dev/null 2>&1 || true

echo ""
echo "▶️  ЧИТАЙ ЗАРАЗ"
echo ""
./build/recorder-cli record "$SECONDS_TO_RECORD" --dir "$OUT"

SESSION=$(find "$OUT" -maxdepth 1 -mindepth 1 -type d | head -1)

echo ""
echo "==> Транскрибую канал клієнта"
afconvert -f WAVE -d LEI16@16000 -c 1 "$SESSION/system.caf" "$OUT/client.wav" >/dev/null

MODEL=$(ls "$HOME"/dev/models/ggml-medium* "$HOME"/dev/models/ggml-small* 2>/dev/null | head -1)
[[ -n "$MODEL" ]] || { echo "❌ немає моделі у ~/dev/models"; exit 1; }
echo "    модель: $(basename "$MODEL")"

# Same flags the product uses — measuring anything else would measure a tool we do
# not ship.
/opt/homebrew/bin/whisper-cli -m "$MODEL" -f "$OUT/client.wav" -l uk \
  --suppress-nst --no-speech-thold 0.8 \
  -otxt -of "$OUT/client" --no-prints >/dev/null 2>&1

echo ""
echo "════════════════════════════════════════════════════════"
echo "  Результат: жива мова крізь дзвінок"
echo "════════════════════════════════════════════════════════"
echo ""
$PYTHON Tools/wer.py "$REFERENCE" "$OUT/client.txt"

echo ""
echo "── Що почула модель ──"
cat "$OUT/client.txt"
echo ""
echo "Файли: $OUT"
