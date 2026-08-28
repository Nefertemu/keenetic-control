#!/bin/bash
# Сборка Keenetic Control.app — один шаг от исходников до готового приложения.
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$PWD"
APP_NAME="Keenetic Control"
BUNDLE="$ROOT/dist/$APP_NAME.app"
BINARY="KeeneticControl"
VERSION="1.0"

# Макросы SwiftUI живут в Xcode, а не в Command Line Tools.
if [ -d "/Applications/Xcode.app/Contents/Developer" ] && \
   [ "$(xcode-select -p 2>/dev/null)" != "/Applications/Xcode.app/Contents/Developer" ]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

echo "==> Сборка (release)"
swift build -c release --product "$BINARY"
BUILT="$(swift build -c release --product "$BINARY" --show-bin-path)/$BINARY"

echo "==> Иконка"
swiftc -O Tools/MakeIcon.swift -o .build/makeicon
ICONSET="$ROOT/.build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
.build/makeicon "$ROOT/.build/icon-1024.png" > /dev/null

for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
            "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
            "512 512x512" "1024 512x512@2x"; do
    set -- $spec
    sips -z "$1" "$1" "$ROOT/.build/icon-1024.png" --out "$ICONSET/icon_$2.png" > /dev/null
done
iconutil -c icns "$ICONSET" -o "$ROOT/.build/AppIcon.icns"

echo "==> Сборка бандла"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BUILT" "$BUNDLE/Contents/MacOS/$BINARY"
cp "$ROOT/.build/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                 <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>          <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>           <string>$BINARY</string>
    <key>CFBundleIdentifier</key>           <string>pro.netcraze.KeeneticControl</string>
    <key>CFBundleIconFile</key>             <string>AppIcon</string>
    <key>CFBundlePackageType</key>          <string>APPL</string>
    <key>CFBundleShortVersionString</key>   <string>$VERSION</string>
    <key>CFBundleVersion</key>              <string>$VERSION</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key>       <string>14.0</string>
    <key>LSApplicationCategoryType</key>    <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>      <true/>
    <key>NSHumanReadableCopyright</key>     <string>Keenetic Control</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <!-- Веб-панель роутера в локальной сети живёт по http, без сертификата. -->
        <key>NSAllowsArbitraryLoads</key>   <true/>
    </dict>
</dict>
</plist>
PLIST

printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

# Ад-хок подпись даёт требование вида cdhash — оно меняется с каждой
# сборкой, и связка ключей каждый раз заново спрашивает доступ к паролям.
# Подпись сертификатом даёт требование по идентификатору бандла, оно
# переживает пересборку, и разрешение выдаётся один раз навсегда.
IDENTITY="${KC_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk 'NR==1 && /\)/ {print $2}')"
fi

echo "==> Подпись"
if [ -n "$IDENTITY" ]; then
    NAME="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -m1 "$IDENTITY" | sed 's/.*"\(.*\)"/\1/')"
    echo "    сертификат: ${NAME:-$IDENTITY}"
    codesign --force --deep --sign "$IDENTITY" "$BUNDLE"
else
    echo "    сертификата подписи нет — подписываю ад-хок"
    echo "    связка ключей будет заново спрашивать доступ после каждой сборки"
    codesign --force --deep --sign - "$BUNDLE"
fi
codesign --verify --verbose=1 "$BUNDLE" 2>&1 | sed 's/^/    /'
codesign -d -r- "$BUNDLE" 2>&1 | grep -i "^designated" | sed 's/^/    /'

echo
echo "Готово: $BUNDLE"
