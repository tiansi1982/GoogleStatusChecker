# GoogleStatusChecker

> A tiny macOS status-bar app that tells you, at a glance, whether your current network can reach **Google US**.

[![Platform](https://img.shields.io/badge/platform-macOS%2011%2B-success.svg)](https://www.apple.com/macos/)
[![Architecture](https://img.shields.io/badge/arch-Apple%20Silicon%20(arm64)-blue.svg)](https://developer.apple.com/documentation/apple-silicon)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](#license)
[![Swift](https://img.shields.io/badge/language-Swift-orange.svg)](https://swift.org/)
[![Dependencies](https://img.shields.io/badge/dependencies-None-lightgrey.svg)](#tech-stack)

GoogleStatusChecker puts a colored indicator light in your macOS menu bar (top-right corner). It periodically probes whether your current network can reach Google US (`www.google.com`) and reflects the result in real time with **red / yellow / green**. Handy for checking which region your proxy / VPN is exiting from, or for troubleshooting connectivity.

## Indicator meaning

| Light | Meaning | Triggered when |
| :---: | :--- | :--- |
| 🟢 Green | **Google US** is reachable | Lands on `www.google.com` with no country redirect and no non-US `kHL`/`gl` marker |
| 🟡 Yellow | Google reachable, but **not the US version** | Redirected to a country domain (e.g. `google.co.jp`, `google.com.hk`), or the page JS/meta-redirects to another Google domain, or a non-US country code is detected |
| 🔴 Red | Google is **unreachable** | Connection timeout / error / non-2xx–3xx status / the final landing domain isn't Google |
| ⚪ Gray | Checking | A request is in flight, no result yet |

## How it works

A check runs automatically every **5 minutes**. The flow:

1. Request `https://www.google.com/` with a desktop Chrome User-Agent (`Accept-Language: en-US,en;q=0.9`).
2. Use an **ephemeral session** (`URLSessionConfiguration.ephemeral`): no cookies, no cache, `reloadIgnoringLocalCacheData` — every probe is real.
3. Follow HTTP redirects and record the final landing URL.
4. Judgment logic:
   - Timeout / error / status not in `200..<400` / landing host doesn't contain `google` → **Red**
   - Lands on `www.google.com` / `google.com`, then scan the page content:
     - Detect `location.replace(...)` / `location.href = ...` / `<meta refresh>` pointing to another Google domain → **Yellow**
     - Detect `kHL="xx-XX"`, `gl=XX` country markers → `US` is green, anything else is yellow
     - None of the above → default **Green** (treated as the US version)
   - Lands on another `google.*` domain (e.g. `google.co.jp`) → **Yellow**

The reason for looking at the page body rather than just the status code: in many networks `google.com` itself opens fine, but the page then JS-redirects you to a regional version in the front end. A naive HTTP check would be fooled. This app inspects both the final URL and the in-page redirect / country markers.

## Requirements

- **macOS 11.0 (Big Sur) or later**
- **Apple Silicon (arm64)** — only arm64 is built by default; for Intel support see [Custom build](#custom-build) below
- Building from source requires Xcode Command Line Tools (`xcode-select --install`)

## Quick start

### Option A: Build from source (recommended)

```bash
# 1. Install command-line tools (skip if already installed)
xcode-select --install

# 2. Enter the project directory and build in one shot
cd GoogleStatusChecker
./build.sh

# 3. Run
open GoogleStatusChecker.app
```

The build product `GoogleStatusChecker.app` is produced in the current directory. A circular indicator appears in the top-right menu bar.

### Option B: Use a prebuilt .app

If you got a prebuilt `GoogleStatusChecker.app` from someone else (copied / downloaded):

```bash
# 1. Remove the quarantine attribute (otherwise macOS shows "damaged" / "cannot verify developer")
xattr -cr /path/to/GoogleStatusChecker.app

# 2. First launch: right-click -> Open (don't double-click), then click "Open" in the dialog
#    After allowing once, you can double-click to launch normally afterward
open /path/to/GoogleStatusChecker.app
```

> Because the app is ad-hoc signed (no Apple Developer notarization), a copy from elsewhere gets blocked by Gatekeeper on first launch and needs the two steps above. Building it on your own machine has no such issue.

## Usage

Once running, the app lives **only in the menu bar** and takes **no Dock space** (`LSUIElement=true` in `Info.plist`).

**Click the indicator** to open the menu:

| Menu item | Action |
| :--- | :--- |
| Status: xxx | Current check result (display only, not clickable) |
| Last check: HH:mm:ss | Time of the most recent check |
| Recheck now (⌘R) | Run a check immediately, no need to wait for the timer |
| Open Google in browser (⌘O) | Open `https://www.google.com/` in the default browser |
| Quit GoogleStatusChecker (⌘Q) | Quit the app |

Hovering the indicator also shows a text tooltip with the current status.

### Launch at login

Drag `GoogleStatusChecker.app` into **System Settings → General → Login Items & Extensions → Login Items** (macOS Ventura and later), or click `+` in "Login Items" to add it.

## Sharing with other Macs

This app is single-architecture arm64 and runs on any Apple Silicon Mac. To share:

```bash
# Package
zip -r -X GoogleStatusChecker.zip GoogleStatusChecker.app
```

On the target Mac, after unzipping:

```bash
xattr -cr /path/to/GoogleStatusChecker.app
open /path/to/GoogleStatusChecker.app   # first launch: right-click -> Open
```

## Custom build

`build.sh` supports environment variables:

| Variable | Default | Description |
| :--- | :--- | :--- |
| `ARCHS` | `arm64` | Target architecture. Set to `"arm64 x86_64"` to build a universal binary (also supports Intel Macs) |
| `MIN_OS` | `11.0` | Minimum supported OS version |

Examples:

```bash
# Build universal (Intel + Apple Silicon)
ARCHS="arm64 x86_64" ./build.sh

# Raise the minimum OS requirement to macOS 13
MIN_OS=13.0 ./build.sh
```

### Change the check interval

The interval is hard-coded in `main.swift`:

```swift
private static let checkInterval: TimeInterval = 300 // auto-check every 5 minutes
```

Change it to your desired number of seconds, then re-run `./build.sh`.

## Project structure

```
GoogleStatusChecker/
├── main.swift       # All source (~400 lines, pure Swift + AppKit, no third-party deps)
├── Info.plist       # App config (LSUIElement=true hides the Dock icon)
├── build.sh         # One-shot build & package script
└── README.md        # This document
```

## Debugging

View runtime logs (`print` output goes to the system log):

```bash
open GoogleStatusChecker.app && \
log stream --predicate 'process == "GoogleStatusChecker"' --style compact
```

Yellow / red paths print the detected redirect target or country code, which helps with troubleshooting.

## FAQ

**Q: Double-clicking the .app shows "damaged" or "cannot verify developer"?**
A: The app uses ad-hoc signing (no Apple notarization). Run `xattr -cr /path/to/GoogleStatusChecker.app` in Terminal to strip the quarantine attribute, then right-click → Open to allow it once.

**Q: I can open Google fine, so why is it yellow?**
A: Your network can reach Google, but Google redirected you to a non-US version (e.g. `google.co.jp`, `google.com.hk`). The yellow light is exactly to flag this — "Google works, but not US Google." Check your proxy/VPN exit region.

**Q: It's stuck on red, but my browser opens Google?**
A: The app probes with an ephemeral, cache-disabled session, which is stricter than the browser (that may use local DNS cache or cookies). Click "Recheck now" first; if still red, use `log stream` to see the reason (timeout / status code / non-google domain).

**Q: Does it sneak traffic in the background?**
A: No. The app requests `https://www.google.com/` exactly once every 5 minutes — no uploads, no cookies, no cache, no telemetry. It's a single source file, so you can audit it yourself.

**Q: How do I fully uninstall?**
A: Click "Quit GoogleStatusChecker" in the menu, then delete `GoogleStatusChecker.app`. The app writes no config files and stores no data — delete and it's gone.

## Tech stack

- Language: Swift
- Frameworks: Cocoa / AppKit / URLSession
- Dependencies: none — system frameworks only
- Build: `swiftc` + `lipo` + `codesign`, no Xcode project needed

## License

MIT License © 2026 tiansi
