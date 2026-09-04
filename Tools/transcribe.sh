#!/bin/zsh
# Local transcription of a session into transcript.md (P5 bonus, Task 16).
#
#   Tools/transcribe.sh <тека-сесії> [модель]
#
# Speaker attribution costs nothing here, and that is the point. Most transcription
# pipelines have to guess who spoke — diarisation, with its own error rate. This one
# does not: mic.caf is the advisor by construction and system.caf is the client, so
# the two tracks are transcribed separately and simply labelled. What normally needs
# a model is settled by the recording topology.
#
# Everything runs on the machine. Audio never leaves the advisor's Mac — the same
# constraint that governs the recorder governs the transcript (ТЗ F-3).
set -euo pipefail

cd "$(dirname "$0")/.."

SESSION="${1:?вкажи теку сесії}"
MODEL="${2:-$HOME/dev/models/ggml-small-q5_1.bin}"
LANG="${LANG_CODE:-uk}"
WHISPER="/opt/homebrew/bin/whisper-cli"
PYTHON=".venv/bin/python"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

[[ -f "$MODEL" ]] || { echo "❌ немає моделі: $MODEL"; exit 1; }
[[ -x "$WHISPER" ]] || { echo "❌ немає whisper-cli (brew install whisper-cpp)"; exit 1; }

echo "==> Готую аудіо (whisper приймає 16 кГц mono)"
for track in mic system; do
  [[ -f "$SESSION/$track.caf" ]] || { echo "❌ немає $track.caf"; exit 1; }
  afconvert -f WAVE -d LEI16@16000 -c 1 "$SESSION/$track.caf" "$WORK/$track.wav" >/dev/null
done

for track in mic system; do
  echo "==> Транскрибую $track"
  "$WHISPER" -m "$MODEL" -f "$WORK/$track.wav" -l "$LANG" -oj -of "$WORK/$track" \
    --no-prints 2>/dev/null || {
      echo "❌ whisper не впорався з $track"; exit 1;
    }
done

echo "==> Складаю transcript.md"
$PYTHON - "$SESSION" "$WORK" "$MODEL" <<'PY'
import json
import sys
from pathlib import Path

session, work, model = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
meta = json.loads((session / "meta.json").read_text())


def stamp(ms: int) -> str:
    total = ms // 1000
    return f"{total // 3600:02d}:{total % 3600 // 60:02d}:{total % 60:02d}"


def segments(track: str) -> list[tuple[int, str]]:
    data = json.loads((work / f"{track}.json").read_text())
    out = []
    for item in data.get("transcription", []):
        text = item["text"].strip()
        if not text or text.startswith("["):
            continue  # whisper marks non-speech as [BLANK_AUDIO] and similar
        out.append((item["offsets"]["from"], text))
    return out


lines = [
    "# Транскрипт сесії",
    "",
    f"**Сесія:** {meta['sessionId']}",
    f"**Початок:** {meta['startedAt']}",
    f"**Тривалість:** {stamp(meta['durationMs'])}",
    f"**Модель:** whisper.cpp `{model.name}` — локально, аудіо не залишає цей Mac",
    "",
    "> Розділення за спікерами не вгадується: `mic.caf` — це завжди радник,",
    "> `system.caf` — завжди співрозмовник. Атрибуція реплік випливає з того,",
    "> як зроблено запис, а не з моделі діаризації.",
    "",
]

for track, title in (("mic", "Радник"), ("system", "Клієнт")):
    items = segments(track)
    lines.append(f"## {title}")
    lines.append("")
    if not items:
        lines.append("_(тиша — у цьому каналі мовлення не розпізнано)_")
    else:
        for offset, text in items:
            lines.append(f"`[{stamp(offset)}]` {text}")
    lines.append("")

target = session / "transcript.md"
target.write_text("\n".join(lines), encoding="utf-8")
print(f"    ✅ {target}")
for track, title in (("mic", "Радник"), ("system", "Клієнт")):
    print(f"    {title}: {len(segments(track))} реплік")
PY
