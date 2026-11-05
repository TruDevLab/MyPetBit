#!/bin/bash
# Собирает build/MyPetBit.app из Swift Package (Xcode не нужен). Обычно вызывается из Makefile: make bundle.
# Подпись: сертификатом «MyPetBit Dev Signing», если он есть (make cert), иначе локальная (ad-hoc).
# С сертификатом macOS не переспрашивает разрешения (Календарь, «Загрузки») после каждой пересборки.
set -euo pipefail
cd "$(dirname "$0")/.."

CONF="${CONF:-release}"
IDENTITY="${IDENTITY:-MyPetBit Dev Signing}"

swift build -c "$CONF" --product MyPetBit
swift build -c "$CONF" --product MyPetBitMedia
BIN="$(swift build -c "$CONF" --show-bin-path)"

APP=build/MyPetBit.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MyPetBit" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
# Номер сборки растёт со временем: две сборки одной версии различимы.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%y%m%d%H%M)" "$APP/Contents/Info.plist"
# Иконку перерисовывает tools/make-icon.swift (команда в его шапке).
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Переводы интерфейса: русский — язык разработки (ключи), английский и китайский — в .lproj.
cp -R Resources/*.lproj "$APP/Contents/Resources/"
# Шаблоны интеграций и хук zsh — для кнопок «Подключить» в настройках и знакомстве.
cp -R integrations "$APP/Contents/Resources/"
cp tools/mypetbit.zsh "$APP/Contents/Resources/"
# Помощник для музыки — отдельным бандлом со своим bundle id (см. Sources/MyPetBitMedia/main.swift).
HELPER="$APP/Contents/XPCServices/MyPetBitMedia.xpc"
mkdir -p "$HELPER/Contents/MacOS"
cp "$BIN/MyPetBitMedia" "$HELPER/Contents/MacOS/"
cp Helper/Info.plist "$HELPER/Contents/"
# Скопированным файлам macOS ставит служебные атрибуты, а codesign считает их мусором в бандле.
xattr -cr "$APP"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
    # Вложенный бандл подписывается первым, иначе подпись приложения не сойдётся.
    codesign --force --sign "$IDENTITY" "$HELPER"
    codesign --force --sign "$IDENTITY" "$APP"
    echo "Подписано: $IDENTITY"
else
    codesign --force --sign - "$HELPER"
    codesign --force --sign - "$APP"
    echo "Подписано локально (ad-hoc). Чтобы разрешения переживали пересборку: make cert"
fi

echo "Готово: $APP"
