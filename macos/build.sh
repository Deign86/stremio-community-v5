#!/bin/bash
# Builds "Stremio Community.app" into ./build.
#
#   ./build.sh                 # app for this Mac's architecture
#   ARCH=universal ./build.sh  # Intel + Apple Silicon
#   ARCH=arm64 ./build.sh      # Apple Silicon only
#   ./build.sh dmg             # also create build/Stremio-Community-<ver>-<arch>.dmg
#
# Needs only the Xcode Command Line Tools. Run ./fetch-deps.sh first.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=..

VERSION=$(sed -n 's/^project(stremio VERSION "\(.*\)")/\1/p' "$ROOT/CMakeLists.txt")
APP_NAME="Stremio Community"
EXE="StremioCommunity"
MIN_MACOS="11.0"

case "${ARCH:-native}" in
  native) ARCHS=("$(uname -m)") ;;
  universal) ARCHS=(x86_64 arm64) ;;
  x86_64|arm64) ARCHS=("$ARCH") ;;
  *) echo "Unknown ARCH=$ARCH (use native, universal, x86_64 or arm64)"; exit 1 ;;
esac
LABEL=$([ ${#ARCHS[@]} -gt 1 ] && echo universal || echo "${ARCHS[0]}")

for f in vendor/mpv-libs/libmpv.2.dylib vendor/include/mpv/client.h vendor/node/node vendor/server.js; do
  [ -e "$f" ] || { echo "Missing $f - run ./fetch-deps.sh first"; exit 1; }
done

BUILD=build
APP="$BUILD/$APP_NAME.app"
OBJ="$BUILD/obj"
rm -rf "$APP" "$OBJ"
mkdir -p "$OBJ" "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"

# Thin (or keep) a fat binary for the selected architectures.
thin() {
  local src="$1" dst="$2"
  if [ ${#ARCHS[@]} -gt 1 ]; then cp "$src" "$dst"; else lipo "$src" -thin "${ARCHS[0]}" -output "$dst"; fi
}

echo "==> Compiling (${ARCHS[*]})"
SWIFT_FLAGS=(-O -swift-version 5 -import-objc-header Sources/Bridge.h -I vendor/include
  -L vendor/mpv-libs -lmpv.2
  -framework AppKit -framework WebKit -framework OpenGL -framework QuartzCore -framework MediaPlayer
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks)
BINS=()
for a in "${ARCHS[@]}"; do
  swiftc "${SWIFT_FLAGS[@]}" -target "$a-apple-macos$MIN_MACOS" Sources/*.swift -o "$OBJ/$EXE-$a"
  BINS+=("$OBJ/$EXE-$a")
done
lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/$EXE"

echo "==> Bundling"
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

for lib in vendor/mpv-libs/*.dylib; do
  thin "$lib" "$APP/Contents/Frameworks/$(basename "$lib")"
done
thin vendor/node/node "$APP/Contents/Resources/node"
chmod +x "$APP/Contents/Resources/node"
cp vendor/server.js "$APP/Contents/Resources/server.js"
cp Resources/shell-watchdog.js "$APP/Contents/Resources/"
# Same default mpv config as the Windows build (Anime4K shaders, input.conf, skip-intro).
bsdtar -xf "$ROOT/utils/mpv/Default Portable Config.7z" -C "$APP/Contents/Resources"
cp "$ROOT/images/stremio.png" "$APP/Contents/Resources/splash.png"
mkdir -p "$APP/Contents/Resources/licenses"
cp "$ROOT/LICENSE.md" "$APP/Contents/Resources/licenses/LICENSE.md"
[ -f vendor/node/LICENSE ] && cp vendor/node/LICENSE "$APP/Contents/Resources/licenses/node-LICENSE"

echo "==> Icon"
ICONSET="$OBJ/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ROOT/images/stremio2.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2)); [ $d -gt 512 ] && d=512
  sips -z $d $d "$ROOT/images/stremio2.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> Signing (ad-hoc)"
codesign --force --sign - "$APP"/Contents/Frameworks/*.dylib 2>/dev/null
codesign --force --sign - "$APP/Contents/Resources/node" 2>/dev/null
codesign --force --sign - "$APP"
codesign --verify --deep "$APP" && echo "signature ok"

echo "==> Built $APP ($(du -sh "$APP" | cut -f1), $LABEL)"

if [ "${1:-}" = "dmg" ]; then
  DMG="$BUILD/Stremio-Community-$VERSION-$LABEL.dmg"
  STAGE="$OBJ/dmg"
  rm -rf "$STAGE" "$DMG"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  echo "==> Built $DMG ($(du -sh "$DMG" | cut -f1))"
fi
