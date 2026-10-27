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
- **Not supported:** Chrome extensions (uBlock, Stylus, PreMiD) and the auto-updater. Thumbfast needs
  a standalone `mpv` binary for its thumbnail process.
