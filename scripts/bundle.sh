#!/bin/bash
# Локальная сборка .app с сертификатом "AviaCalls Signing": разрешения macOS переживают пересборку.
# Сертификат лежит в ~/.config/aviacalls/signing, в кейчейн импортируй signing.p12 (пароль в p12.pass).
# Релиз для коллег собирает CI тем же сертификатом, см. scripts/ci-keychain.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
make app SIGN="${SIGN_IDENTITY:-AviaCalls Signing}" APP_VERSION="${APP_VERSION:-0.0.0-dev}" | tail -1
echo build/AviaCalls.app
