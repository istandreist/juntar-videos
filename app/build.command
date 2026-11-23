#!/bin/bash
# Compila "Join Videos.app" (binário universal Intel + Apple Silicon), assina "ad hoc" e cria o JuntarVideos.dmg
cd "$(dirname "$0")" || exit 1
set -e

APP="build/Join Videos.app"
RES="$APP/Contents/Resources"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$RES"
cp Info.plist "$APP/Contents/Info.plist"

echo "A compilar (Intel)…"
swiftc -O -parse-as-library -target x86_64-apple-macos13.0 Sources/*.swift -o build/JV_x86

echo "A compilar (Apple Silicon)…"
swiftc -O -parse-as-library -target arm64-apple-macos13.0 Sources/*.swift -o build/JV_arm

lipo -create build/JV_x86 build/JV_arm -output "$APP/Contents/MacOS/JuntarVideos"
echo "Arquiteturas incluídas: $(lipo -archs "$APP/Contents/MacOS/JuntarVideos")"

echo "A juntar ícone e idiomas…"
iconutil -c icns Resources/AppIcon.iconset -o "$RES/AppIcon.icns"
for L in en pt-PT pt-BR es; do
  mkdir -p "$RES/$L.lproj"
  cp Resources/$L.lproj/*.strings "$RES/$L.lproj/"
done

echo "A assinar…"
codesign --force --deep --sign - "$APP"

echo "A criar o DMG…"
mkdir -p build/dmg
cp -R "$APP" build/dmg/
ln -sf /Applications build/dmg/Applications
rm -f JuntarVideos.dmg
hdiutil create -volname "Join Videos" -srcfolder build/dmg -ov -format UDZO JuntarVideos.dmg >/dev/null

echo
echo "Pronto: $(pwd)/JuntarVideos.dmg"
if [ -z "$CI" ]; then open -R JuntarVideos.dmg; fi
