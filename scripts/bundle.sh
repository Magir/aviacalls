#!/bin/bash
# Локальная сборка .app с подписью Apple Development: разрешения macOS переживают пересборку.
# Для раздачи коллегам — `make zip` (ad-hoc подпись), см. Makefile и install.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
make app SIGN="${SIGN_IDENTITY:-Apple Development}" APP_VERSION="${APP_VERSION:-0.0.0-dev}" | tail -1
echo build/AviaCalls.app
