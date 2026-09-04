#!/bin/zsh
# Acceptance run for ТЗ criterion #1: inter-channel drift over a full 60 minutes.
#
# Launched with `open` (not from a shell) on purpose — that makes the process a child
# of Terminal, and on this bench the TCC grants for system-audio and microphone
# capture belong to Terminal. The same script run over SSH records digital silence.
#
# `caffeinate -s` keeps the Mac awake for the whole hour; closing this window kills
# the run.

cd "$HOME/dev/STLTH-Recorder-for-macOS" || exit 1

OUT_DIR="/tmp/stlth-drift-60min"
LOG="$OUT_DIR/run.log"
mkdir -p "$OUT_DIR"

clear
echo "STLTH Recorder for macOS — приймальний прогін дрейфу, 60 хвилин"
echo "Почато: $(date '+%H:%M:%S')"
echo "Лог: $LOG"
echo ""
echo "Не закривай це вікно — прогін помре разом з ним."
echo ""

caffeinate -s ./Tools/twochannel-run.sh 3600 "$OUT_DIR" 2>&1 | tee "$LOG"
echo "exit=${pipestatus[1]}" >> "$LOG"

echo ""
echo "Завершено: $(date '+%H:%M:%S')"
