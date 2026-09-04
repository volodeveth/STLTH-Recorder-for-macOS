#!/bin/zsh
# GATE-1: запустити ЦЕЙ скрипт у Terminal НА VNC-екрані (не по SSH!),
# інакше macOS не покаже діалог дозволу на запис системного звуку.
#
#   ~/dev/spike-tap/gate1.sh
#
# Коли зʼявиться діалог «"tapprobe" хоче записувати звук з інших застосунків» —
# натисніть «Дозволити» / «Allow», після чого скрипт запуститься ще раз сам.

cd "$(dirname "$0")" || exit 1

run_probe() {
  echo "▶️  Відтворюю тестовий тон і захоплюю $1 с…"
  afplay /tmp/tone.wav &
  local af=$!
  sleep 1
  ./tapprobe "$1"
  local code=$?
  kill $af 2>/dev/null
  return $code
}

if [[ ! -f /tmp/tone.wav ]]; then
  echo "Немає /tmp/tone.wav — генерую системним звуком натомість"
  cp /System/Library/Sounds/Submarine.aiff /tmp/tone.wav 2>/dev/null
fi

echo "=== Спроба 1 (тут має зʼявитися діалог дозволу) ==="
run_probe 8
first=$?

if [[ $first -eq 2 ]]; then
  echo
  echo "=== Тиша. Якщо ви щойно натиснули «Дозволити» — пробуємо ще раз ==="
  echo "(якщо діалогу не було: System Settings → Privacy & Security →"
  echo " Audio Recording / Запис звуку — додайте tapprobe вручну)"
  sleep 3
  run_probe 8
  second=$?
  echo
  echo "Підсумковий код: $second  (0 = GATE-1 ПРОЙДЕНО, 2 = все ще тиша)"
  exit $second
fi

echo
echo "Підсумковий код: $first  (0 = GATE-1 ПРОЙДЕНО)"
exit $first
