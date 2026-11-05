#!/bin/bash
# Собирает образ build/MyPetBit-<версия>.dmg: приложение, ярлык «Программы» и инструкция по установке на трёх языках,
# в окне в стиле Бита (фон — tools/make-dmg-background.swift, раскладка — tools/dmg-window.applescript). Как в Trunook:
# образ сначала изменяемый, Finder обставляет окно (пишет .DS_Store), потом образ сжимается.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
VOLUME="MyPetBit $VERSION"
DMG="build/MyPetBit-$VERSION.dmg"
RWDMG="build/MyPetBit-rw.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"; hdiutil detach -quiet "/Volumes/$VOLUME" 2>/dev/null || true; rm -f "$RWDMG"' EXIT

# Том с прошлого неудачного захода иначе примонтируется вторым («… 1»), и обставится не он.
hdiutil detach -quiet "/Volumes/$VOLUME" 2>/dev/null || true
rm -f "$DMG" "$RWDMG"

cp -R build/MyPetBit.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp Resources/dmg-readme.txt "$STAGE/Install - Установка - 安装.txt"
# Пустой .fseventsd с меткой no_log: иначе система заведёт его сама, и он останется лишней папкой.
mkdir -p "$STAGE/.fseventsd" "$STAGE/.background"
touch "$STAGE/.fseventsd/no_log"
# Фон — кодом, в один tiff на две плотности: Finder сам берёт нужную.
swift tools/make-dmg-background.swift "$VERSION" >/dev/null
tiffutil -cathidpicheck build/dmg-background.png build/dmg-background@2x.png -out "$STAGE/.background/background.tiff" >/dev/null

hdiutil create -quiet -volname "$VOLUME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RWDMG"
hdiutil attach -quiet -noverify -noautoopen "$RWDMG"
osascript tools/dmg-window.applescript "$VOLUME"
sync
hdiutil detach -quiet "/Volumes/$VOLUME"
hdiutil convert -quiet "$RWDMG" -format UDZO -imagekey zlib-level=9 -o "$DMG"
echo "Образ: $DMG"
shasum -a 256 "$DMG"
