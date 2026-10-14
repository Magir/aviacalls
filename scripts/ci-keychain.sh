#!/bin/bash
# CI: кладёт сертификат подписи из секретов во временный кейчейн и доверяет ему.
# Сертификат самоподписанный (~/.config/aviacalls/signing у Ивана): macOS привязывает выданные
# разрешения к подписи, с ad-hoc они слетали при каждом обновлении.
set -euo pipefail
: "${SIGN_CERT_P12:?}" "${SIGN_CERT_PASSWORD:?}"
KC="$RUNNER_TEMP/sign.keychain-db"
security create-keychain -p "" "$KC"
security set-keychain-settings -lut 21600 "$KC"
security unlock-keychain -p "" "$KC"
printf '%s' "$SIGN_CERT_P12" | base64 --decode > "$RUNNER_TEMP/sign.p12"
security import "$RUNNER_TEMP/sign.p12" -k "$KC" -P "$SIGN_CERT_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "" "$KC" >/dev/null
security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')
security find-certificate -c "AviaCalls Signing" -p "$KC" > "$RUNNER_TEMP/sign.pem"
sudo security add-trusted-cert -d -r trustRoot -p codeSign -k /Library/Keychains/System.keychain "$RUNNER_TEMP/sign.pem"
security find-identity -v -p codesigning "$KC" | grep -q "AviaCalls Signing"
