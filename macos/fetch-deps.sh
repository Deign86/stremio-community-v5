#!/bin/bash
# Downloads the third-party pieces into ./vendor:
#   - libmpv + its libraries (taken from the official IINA release, universal)
#   - matching mpv headers
#   - Node.js (official build, universal via lipo, checksum verified)
#   - Stremio's streaming server (server.js from dl.strem.io)
set -euo pipefail
cd "$(dirname "$0")"

IINA_VERSION="v1.5.0"
MPV_TAG="v0.41.0"           # mpv version inside that IINA release
NODE_MAJOR="22"
SERVER_VERSION="v4.20.16"

TMP="$(mktemp -d)"
trap 'hdiutil detach "$TMP/mnt" -quiet 2>/dev/null || true; rm -rf "$TMP"' EXIT
mkdir -p vendor/mpv-libs vendor/include/mpv vendor/node

echo "==> IINA $IINA_VERSION (libmpv)"
curl -fSL -o "$TMP/iina.dmg" "https://github.com/iina/iina/releases/download/$IINA_VERSION/IINA.$IINA_VERSION.dmg"
mkdir -p "$TMP/mnt"
hdiutil attach -nobrowse -readonly -mountpoint "$TMP/mnt" "$TMP/iina.dmg" >/dev/null
rm -f vendor/mpv-libs/*.dylib
cp "$TMP/mnt/IINA.app/Contents/Frameworks/"*.dylib vendor/mpv-libs/
rm -f vendor/mpv-libs/libswift_Concurrency.dylib
hdiutil detach "$TMP/mnt" -quiet

echo "==> mpv headers $MPV_TAG"
for h in client.h render.h render_gl.h stream_cb.h; do
  curl -fsSL -o "vendor/include/mpv/$h" "https://raw.githubusercontent.com/mpv-player/mpv/$MPV_TAG/include/mpv/$h"
done

echo "==> Node.js $NODE_MAJOR LTS"
NODE_VERSION=$(curl -fsSL https://nodejs.org/dist/index.json |
  python3 -I -c "import sys,json;print([x['version'] for x in json.load(sys.stdin) if x['version'].startswith('v$NODE_MAJOR.')][0])")
curl -fsSL -o "$TMP/SHASUMS256.txt" "https://nodejs.org/dist/$NODE_VERSION/SHASUMS256.txt"
for a in x64 arm64; do
  f="node-$NODE_VERSION-darwin-$a.tar.gz"
  curl -fSL -o "$TMP/$f" "https://nodejs.org/dist/$NODE_VERSION/$f"
  (cd "$TMP" && grep " $f\$" SHASUMS256.txt | shasum -a 256 -c -)
  mkdir -p "$TMP/node-$a"
  tar -xzf "$TMP/$f" -C "$TMP/node-$a" --strip-components=1
done
lipo -create "$TMP/node-x64/bin/node" "$TMP/node-arm64/bin/node" -output vendor/node/node
cp "$TMP/node-x64/LICENSE" vendor/node/LICENSE
echo "$NODE_VERSION" > vendor/node/VERSION

echo "==> Stremio server $SERVER_VERSION"
curl -fSL -o vendor/server.js "https://dl.strem.io/server/$SERVER_VERSION/desktop/server.js"

echo "==> Done"
du -sh vendor/*
