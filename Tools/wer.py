#!/usr/bin/env python3
"""Word error rate between a reference text and a transcript.

WER is the standard measure for transcription: the number of word insertions,
deletions and substitutions needed to turn the hypothesis into the reference,
divided by the number of reference words. 0% is perfect, 100% means every word is
wrong, and above 100% is possible when the model invents extra words.

Why this exists at all: "розпізнає добре" is not an engineering claim. Without a
number there is no way to compare models, no way to notice a regression, and no
honest answer to "чи якісно транскрибує".

    python3 Tools/wer.py reference.txt hypothesis.txt
    python3 Tools/wer.py reference.txt --transcript transcript.md --section Радник
"""
from __future__ import annotations

import argparse
import re
import sys
import unicodedata
from pathlib import Path


# Ukrainian numerals as spoken, so a transcript that writes "60%" can be compared
# with a reference that says "шістдесят відсотків". Whisper renders numbers as
# digits; that is a rendering choice, not a recognition error, and counting it as
# one hides how the model actually performed.
NUMERALS = {
    "нуль", "один", "одна", "два", "дві", "три", "чотири", "п'ять", "шість", "сім",
    "вісім", "дев'ять", "десять", "одинадцять", "дванадцять", "тринадцять",
    "чотирнадцять", "п'ятнадцять", "шістнадцять", "сімнадцять", "вісімнадцять",
    "дев'ятнадцять", "двадцять", "тридцять", "сорок", "п'ятдесят", "шістдесят",
    "сімдесят", "вісімдесят", "дев'яносто", "сто", "десятих", "сотих",
    "відсоток", "відсотка", "відсотків", "рік", "роки", "років", "місяць",
    "місяці", "місяців",
}


def drop_numbers(words: list[str]) -> list[str]:
    return [w for w in words
            if not any(ch.isdigit() for ch in w) and w not in NUMERALS]


def normalise(text: str) -> list[str]:
    """Words only: case, punctuation and apostrophe styles must not count as errors."""
    text = unicodedata.normalize("NFC", text).lower()
    text = text.replace("’", "'").replace("`", "'")
    # Keep letters, digits and inner apostrophes; everything else separates words.
    words = re.findall(r"[\w']+", text, flags=re.UNICODE)
    return [w.strip("'") for w in words if w.strip("'")]


def distance(reference: list[str], hypothesis: list[str]) -> tuple[int, int, int]:
    """Levenshtein over words, returning (substitutions, deletions, insertions)."""
    rows, cols = len(reference) + 1, len(hypothesis) + 1
    # cost, then the three operation counters carried along the best path.
    table = [[(0, 0, 0, 0)] * cols for _ in range(rows)]
    for i in range(1, rows):
        table[i][0] = (i, 0, i, 0)
    for j in range(1, cols):
        table[0][j] = (j, 0, 0, j)

    for i in range(1, rows):
        for j in range(1, cols):
            if reference[i - 1] == hypothesis[j - 1]:
                table[i][j] = table[i - 1][j - 1]
                continue
            sub = table[i - 1][j - 1]
            dele = table[i - 1][j]
            ins = table[i][j - 1]
            best = min(sub, dele, ins, key=lambda cell: cell[0])
            if best is sub:
                table[i][j] = (sub[0] + 1, sub[1] + 1, sub[2], sub[3])
            elif best is dele:
                table[i][j] = (dele[0] + 1, dele[1], dele[2] + 1, dele[3])
            else:
                table[i][j] = (ins[0] + 1, ins[1], ins[2], ins[3] + 1)

    _, subs, dels, ins = table[-1][-1]
    return subs, dels, ins


def section_of(transcript: Path, name: str) -> str:
    """Pull one speaker's lines out of a transcript.md."""
    text = transcript.read_text(encoding="utf-8")
    parts = text.split(f"## {name}")
    if len(parts) < 2:
        raise SystemExit(f"У транскрипті немає секції «{name}»")
    body = parts[1].split("\n## ")[0]
    # Strip the `[hh:mm:ss]` stamps.
    return re.sub(r"`\[\d{2}:\d{2}:\d{2}\]`", " ", body)


def main() -> int:
    parser = argparse.ArgumentParser(description="Word error rate for a transcript")
    parser.add_argument("reference", type=Path, help="файл з еталонним текстом")
    parser.add_argument("hypothesis", type=Path, nargs="?", help="файл з розпізнаним текстом")
    parser.add_argument("--transcript", type=Path, help="transcript.md замість hypothesis")
    parser.add_argument("--section", default="Радник", help="секція транскрипту (Радник/Клієнт)")
    args = parser.parse_args()

    reference = normalise(args.reference.read_text(encoding="utf-8"))
    if args.transcript:
        hypothesis = normalise(section_of(args.transcript, args.section))
    elif args.hypothesis:
        hypothesis = normalise(args.hypothesis.read_text(encoding="utf-8"))
    else:
        raise SystemExit("вкажи hypothesis або --transcript")

    if not reference:
        raise SystemExit("еталонний текст порожній")

    subs, dels, ins = distance(reference, hypothesis)
    errors = subs + dels + ins
    wer = errors / len(reference) * 100

    print(f"еталон:      {len(reference)} слів")
    print(f"розпізнано:  {len(hypothesis)} слів")
    print(f"заміни:      {subs}")
    print(f"пропуски:    {dels}")
    print(f"вставки:     {ins}")
    print(f"WER:         {wer:.1f}%")

    # The same comparison with numerals removed from both sides. The gap between the
    # two figures is how much of the error is merely "60%" written where the speaker
    # said "шістдесят відсотків".
    bare_reference, bare_hypothesis = drop_numbers(reference), drop_numbers(hypothesis)
    if bare_reference and len(bare_reference) != len(reference):
        b_subs, b_dels, b_ins = distance(bare_reference, bare_hypothesis)
        bare_wer = (b_subs + b_dels + b_ins) / len(bare_reference) * 100
        print(f"WER без чисел: {bare_wer:.1f}%  "
              f"(прибрано {len(reference) - len(bare_reference)} числових слів)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
