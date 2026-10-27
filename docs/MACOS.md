# Building on macOS

---

## 🚀 Quick Overview

The macOS app lives in [`macos/`](../macos). It is a native Swift/AppKit shell that loads the same
Stremio Web v5 UI as the Windows build and talks to it with the same shell protocol, so the existing
`stremio-web-shell-fixes` UI works unchanged.

| Windows | macOS |
|---|---|
| WebView2 | WKWebView with a transparent background |
| mpv rendering into the HWND (`wid`) | libmpv OpenGL render API (`vo=libmpv`) on a layer behind the web view |
| `stremio-runtime.exe` + `server.js` | Bundled Node.js + `server.js` |
| Tray icon | Menu bar item + app menu |
| File associations / `WM_COPYDATA` | `Info.plist` URL schemes and document types |
| discord-rpc library | Built-in Discord IPC client |

---

## 🛠️ Requirements

- **Operating System**: macOS 11 Big Sur or newer (Intel or Apple Silicon)
- **Tools**: Xcode Command Line Tools (`xcode-select --install`). Full Xcode and Homebrew are not needed.

---

## 📂 Setup Guide

### 1️⃣ **Fetch dependencies**

```bash
cd macos
./fetch-deps.sh
```

This downloads into `macos/vendor/` (git-ignored):

- **libmpv** and its libraries, taken from the official [IINA](https://github.com/iina/iina) release (universal binaries)
- matching **mpv headers**
- **Node.js** LTS from nodejs.org (both architectures, checksums verified, merged with `lipo`)
- Stremio's **server.js** from `dl.strem.io`

### 2️⃣ **Build**

```bash
./build.sh                  # this Mac's architecture
ARCH=universal ./build.sh   # Intel + Apple Silicon
./build.sh dmg              # also build a .dmg
```

The app is written to `macos/build/Stremio Community.app`. The build is ad-hoc signed, so the first
launch of a downloaded copy needs right-click → **Open**.

---

## 🔄 Updates (optional)

The app has a built-in updater that stays **off** unless the build sets an update source:

```bash
swift tools/sign-update.swift generate update.key   # once; prints the public key, keep update.key secret
UPDATE_FEED_URL=https://github.com/<owner>/<repo>/releases/latest/download/macos-update.json \
UPDATE_PUBLIC_KEY=<public key> ./build.sh dmg zip
```

`macos-update.json` lists one zip per architecture (made by `./build.sh zip`) with its SHA-256 and an
Ed25519 signature of `<version>:<arch>:<sha256>`:

```json
{
  "version": "5.0.23",
  "notes": "https://github.com/<owner>/<repo>/releases/tag/v5.0.23-macos",
  "assets": {
    "x86_64": { "url": "https://…/Stremio-Community-5.0.23-macos-x86_64.zip", "sha256": "…", "signature": "…" },
    "arm64":  { "url": "https://…/Stremio-Community-5.0.23-macos-arm64.zip",  "sha256": "…", "signature": "…" }
  }
}
```

The signature is made with `swift tools/sign-update.swift sign update.key "<version>:<arch>:<sha256>"`.
The app checks the feed 15 seconds after launch and then every 6 hours. When there is a newer version,
it downloads it and verifies the signature, checksum, bundle ID and code signature. It then shows the
web UI's "Stremio update available!" dialog, the same one Windows uses, and **Update** swaps the app
bundle and relaunches. Users can also run **Check for Updates…** from the app or menu bar menu, or turn
off **Check for Updates Automatically** (`AutoUpdate=0` in `stremio-settings.ini`).

---

## ⚙️ Runtime layout

- Settings, mpv config, webmods and logs: `~/Library/Application Support/Stremio Community/`
  - `portable_config/` is the mpv config dir. It is seeded from `utils/mpv/Default Portable Config.7z`
    and holds `stremio-settings.ini` with the same keys and `[Security]` allow-lists as Windows.
  - `portable_config/webmods/` holds `.css` and `.js` files injected into the UI, like on Windows.
  - `stremio.log`, `server.log` and `errors.txt` are the app, server and crash logs.
- Debugging: `STREMIO_DEBUG=1 "/Applications/Stremio Community.app/Contents/MacOS/StremioCommunity"`
  logs all shell messages and page console output, and makes the web view inspectable in Safari.

---

## 📝 Notes on platform differences

- **Local web UI proxy.** WebKit blocks an `https://` page from calling the streaming server at
  `http://127.0.0.1:11470` (mixed content); WebView2 allows it. The app serves the hosted UI
  (stremio.zarg.me, with the same fallbacks as Windows) from `http://127.0.0.1:11490`. That origin is a
  secure context that can reach the server, and the Stremio API allows any origin. Responses are
  cached on disk so the app still starts offline.
- **Shell handshake.** `initShellComm()` is retried until the Qt transport sends its init message,
  because in WKWebView `window.onload` can fire before the UI's transport is listening.
- **Fullscreen.** The DOM Fullscreen API is polyfilled to toggle the native window fullscreen, so the
  page stays above the mpv layer.
- **Local files** are passed to the UI as `file://` URLs. A Windows path like `C:\...` parses as a URL
  in Stremio core, but `/Users/...` does not.
- **`vo`** is always `libmpv`; `mpv-set-prop vo` from the UI is ignored.
- **Not supported:** Chrome extensions (uBlock, Stylus, PreMiD). The Windows installer-based updater is
  replaced by the optional updater above. Thumbfast needs
  a standalone `mpv` binary for its thumbnail process.
