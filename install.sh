#!/bin/sh
# Установка AviaCalls: качает последний релиз с GitHub и кладёт в /Applications.
# Файлы, скачанные curl, не получают атрибут карантина, поэтому Gatekeeper
# не блокирует приложение без нотаризации (архивы из браузера — блокирует).
set -e

REPO="Magir/aviacalls"
DEST="${AVIACALLS_INSTALL_DIR:-/Applications}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ -n "${AVIACALLS_ZIP:-}" ]; then
  cp "$AVIACALLS_ZIP" "$TMP/AviaCalls.zip"          # локальная проверка установщика
else
  echo "Скачиваю последний релиз AviaCalls…"
  curl -fsSL -o "$TMP/AviaCalls.zip" "https://github.com/$REPO/releases/latest/download/AviaCalls.zip"
fi
ditto -x -k "$TMP/AviaCalls.zip" "$TMP"

if [ "$DEST" = "/Applications" ]; then
  osascript -e 'tell application "AviaCalls" to quit' >/dev/null 2>&1 || true
  sleep 1
fi
rm -rf "$DEST/AviaCalls.app"
mv "$TMP/AviaCalls.app" "$DEST/"
xattr -dr com.apple.quarantine "$DEST/AviaCalls.app" 2>/dev/null || true

echo "Установлено: $DEST/AviaCalls.app"
echo "При первом запуске выдай разрешения из меню AviaCalls: Универсальный доступ, уведомления, запись экрана."
echo "Микрофон и запись звука Zoom приложение попросит само на первой встрече."
if [ "$DEST" = "/Applications" ]; then
  open "$DEST/AviaCalls.app"
fi
