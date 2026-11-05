#!/bin/bash
# Создаёт самоподписанный сертификат для подписи MyPetBit (по образцу Trunook). Запускается один раз: make cert
#
# Зачем: ad-hoc подпись меняет хеш кода при каждой сборке, а macOS привязывает выданные разрешения
# (Календарь, «Загрузки», управление Терминалом) к подписи — без стабильного сертификата доступ
# переспрашивается после каждой пересборки. Сертификат живёт только в вашей связке ключей.
set -euo pipefail

NAME="${1:-MyPetBit Dev Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
    echo "Сертификат «$NAME» уже есть и пригоден для подписи."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS="$(openssl rand -hex 16)"

echo "Создаю ключ и сертификат…"
openssl req -x509 -newkey rsa:2048 -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -days 3650 -nodes \
    -subj "/CN=$NAME/O=MyPetBit" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
openssl pkcs12 -export -legacy -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/cert.p12" -passout "pass:$PASS" -name "$NAME" 2>/dev/null

echo "Импортирую в связку ключей…"
# -T разрешает codesign брать ключ без запроса пароля связки при каждой сборке.
security import "$WORK/cert.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign -T /usr/bin/security

echo "Отмечаю сертификат как доверенный только для подписи кода (macOS спросит пароль)…"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

security find-identity -v -p codesigning | grep "$NAME"
echo "Готово. Теперь: make install"
