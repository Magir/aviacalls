#!/bin/bash
# Собирает build/AviaCalls.app и подписывает постоянным сертификатом:
# с ad-hoc подписью macOS после каждой сборки забывает выданные разрешения.
# ponytail: ресурсы SwiftPM-зависимостей ищутся по пути сборки на этой машине;
# для раздачи коллегам перейти на проект Xcode с нормальной упаковкой.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=build/AviaCalls.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/AviaCalls "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
codesign --force --sign "${SIGN_IDENTITY:-Apple Development}" "$APP"
echo "$APP"
