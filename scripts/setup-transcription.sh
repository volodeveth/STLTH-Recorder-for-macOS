#!/bin/zsh
# Everything the optional transcription needs, in one command.
#
#   scripts/setup-transcription.sh
#
# The recorder itself needs none of this. Transcription is a bonus, and its
# dependency — whisper.cpp plus half a gigabyte of model — is deliberately not
# bundled into a recorder whose core job does not require it. But «встановіть
# whisper-cpp і покладіть моделі кудись» is an instruction, not an installer, so
# this script is the installer.
#
# Downloads land in the app's own support directory rather than a developer path,
# and are shared machine-wide if run with write access to /Users/Shared.
set -euo pipefail

MODELS="$HOME/Library/Application Support/STLTHRecorder/Models"
SPEECH="ggml-large-v3-q5_0.bin"           # розпізнавання, ~1 031 МБ
SUPERSEDED="ggml-large-v3-turbo-q5_0.bin" # що ставила 1.2.0; прибирається після заміни
VAD="ggml-silero-v5.1.2.bin"              # VAD, ~864 КБ
BASE="https://huggingface.co/ggerganov/whisper.cpp/resolve/main"
VAD_BASE="https://huggingface.co/ggml-org/whisper-vad/resolve/main"

echo "════════════════════════════════════════════════════════"
echo "  STLTH Recorder for macOS — налаштування транскрибації"
echo "════════════════════════════════════════════════════════"
echo ""

if ! command -v brew >/dev/null; then
  echo "❌ Потрібен Homebrew: https://brew.sh"
  exit 1
fi

echo "==> whisper.cpp"
if command -v whisper-cli >/dev/null; then
  echo "    вже встановлено: $(command -v whisper-cli)"
else
  brew install whisper-cpp
fi

mkdir -p "$MODELS"

fetch() {
  local name="$1" url="$2" size="$3"
  if [[ -s "$MODELS/$name" ]]; then
    echo "    $name — уже на місці ($(du -h "$MODELS/$name" | cut -f1))"
    return
  fi
  echo "    завантажую $name ($size)…"
  # -f so an HTML error page is never saved as a model file.
  curl -fL --progress-bar -o "$MODELS/$name.part" "$url"
  mv "$MODELS/$name.part" "$MODELS/$name"
  echo "    ✅ $name"
}

echo "==> Моделі → $MODELS"
fetch "$SPEECH" "$BASE/$SPEECH" "1 031 МБ"
fetch "$VAD" "$VAD_BASE/$VAD" "864 КБ"

# Only now, after both downloads above succeeded: a failed fetch must never leave
# the machine with no working model at all. Same order the app's installer keeps.
if [[ -e "$MODELS/$SUPERSEDED" ]]; then
  rm -f "$MODELS/$SUPERSEDED" "$MODELS/$SUPERSEDED.part"
  echo "    🧹 $SUPERSEDED прибрано — його замінила $SPEECH"
fi

echo ""
if [[ -s "$MODELS/$SPEECH" && -s "$MODELS/$VAD" ]] && command -v whisper-cli >/dev/null; then
  echo "✅ Готово. У меню застосунку: Останні записи → сесія → Транскрибувати."
  echo ""
  echo "Обидві моделі потрібні. Без VAD (\"$VAD\") розпізнавання"
  echo "вигадує текст у місцях тиші — а зустріч здебільшого з неї й складається."
else
  echo "⚠️  Щось не встановилося — перевір вивід вище."
  exit 1
fi
