#!/bin/zsh
# Measure how well the transcription actually works — as a number, not an impression.
#
#   Tools/transcription-quality.sh
#
# The honest difficulty: to compute a word error rate you need speech whose exact
# text you already know, and no real meeting comes with one. So the reference text is
# spoken by the system voice, and then measured twice:
#
#   1. clean path      — as the microphone track hears it, no loss at all
#   2. through a codec — the same speech re-encoded at meeting bitrate, which is what
#                        the client's track actually receives over Zoom or Meet
#
# The first number is the ceiling: the advisor's own voice on a local microphone.
# The second is the realistic case for the client's channel, and the gap between them
# is the cost the network imposes — not a defect of the transcriber.
#
# A synthetic voice is easier than a human one, so both figures are optimistic. They
# bound the quality from above; they do not represent a live meeting.
set -euo pipefail

cd "$(dirname "$0")/.."

OUT="/tmp/stlth-wer"
MODEL="${MODEL:-$HOME/dev/models/ggml-small-q5_1.bin}"
WHISPER="/opt/homebrew/bin/whisper-cli"
PYTHON=".venv/bin/python"

mkdir -p "$OUT"
rm -f "$OUT/timing.txt"

cat > "$OUT/reference.txt" <<'TEXT'
Доброго дня. Мене звати Володимир, я ваш фінансовий радник.
Сьогодні ми обговоримо структуру вашого портфеля та цілі на найближчі три роки.
Почнімо з того, який рівень ризику для вас комфортний.
Далі подивимось на розподіл між акціями та облігаціями.
Окремо зупинимось на валютній частині заощаджень.
Я поясню, чому диверсифікація важливіша за пошук ідеального моменту для входу.
Наприкінці зустрічі я підсумую домовленості та надішлю вам протокол.
TEXT

echo "==> Синтезую еталонну мову"
say -v Lesya -o "$OUT/clean.aiff" -f "$OUT/reference.txt"
afconvert -f WAVE -d LEI16@16000 -c 1 "$OUT/clean.aiff" "$OUT/clean.wav" >/dev/null

echo "==> Пропускаю ту саму мову крізь кодек зустрічі (AAC 24 кбіт/с)"
# What Zoom and Meet do to speech: lossy compression at conversational bitrate.
afconvert -f m4af -d aac -b 24000 "$OUT/clean.wav" "$OUT/coded.m4a" >/dev/null
afconvert -f WAVE -d LEI16@16000 -c 1 "$OUT/coded.m4a" "$OUT/coded.wav" >/dev/null

# Every model found locally is measured, not just the shipped default: without a
# comparison there is no way to say whether the number is the model's ceiling or
# simply the one we happened to pick.
MODELS=()
for candidate in "$HOME"/dev/models/ggml-*.bin; do
  [[ -f "$candidate" ]] && MODELS+=("$candidate")
done
[[ ${#MODELS[@]} -gt 0 ]] || { echo "❌ немає моделей у ~/dev/models"; exit 1; }

AUDIO_SECONDS=$($PYTHON -c "
import soundfile as sf; print(f'{sf.info(\"$OUT/clean.wav\").duration:.1f}')")

for model in "${MODELS[@]}"; do
  name=$(basename "$model")
  for variant in clean coded; do
    echo "==> Розпізнаю: $variant, модель $name"
    START=$(date +%s.%N)
    "$WHISPER" -m "$model" -f "$OUT/$variant.wav" -l uk -otxt \
      -of "$OUT/${variant}-${name}" --no-prints >/dev/null 2>&1
    END=$(date +%s.%N)
    echo "$name $variant $(echo "$END - $START" | bc)" >> "$OUT/timing.txt"
  done
done

echo ""
echo "════════════════════════════════════════════════════════"
echo "  Якість транскрибації — word error rate"
echo "════════════════════════════════════════════════════════"
for model in "${MODELS[@]}"; do
  name=$(basename "$model")
  size=$(du -h "$model" | cut -f1)
  echo ""
  echo "════ Модель $name ($size) ════"
  for variant in clean coded; do
    case $variant in
      clean) label="Канал радника (локальний мікрофон, без втрат)" ;;
      coded) label="Канал клієнта (крізь кодек зустрічі, 24 кбіт/с)" ;;
    esac
    echo ""
    echo "── $label"
    $PYTHON Tools/wer.py "$OUT/reference.txt" "$OUT/${variant}-${name}.txt" | sed 's/^/   /'
    SECS=$(grep "^$name $variant " "$OUT/timing.txt" | tail -1 | awk '{print $3}')
    echo "   час:         ${SECS} с на ${AUDIO_SECONDS} с аудіо"
    $PYTHON -c "
secs=float('${SECS}'); audio=float('${AUDIO_SECONDS}')
print(f'   годинна сесія: ~{secs/audio*3600/60:.0f} хв на канал')"
  done
done

echo ""
echo "Синтезований голос розпізнається легше за людський, тож обидва числа —"
echo "оцінка зверху. Різниця між ними показує ціну мережевого кодека."
