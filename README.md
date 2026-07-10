# GoogleStatusChecker

A small macOS menu-bar app that checks whether Google is reachable and estimates the country of the current network exit.

## Status lights

| Light | Meaning |
| :---: | :--- |
| 🟢 Green | Google is reachable and the estimated exit country is the United States |
| 🟡 Yellow | Google is reachable and the estimated exit country is not the United States |
| 🔴 Red | Google is unreachable or the Google probe returned an unexpected response |
| 🔵 Blue | Google is reachable, but the exit country could not be determined |
| ⚪ Gray | A check is in progress |

The menu shows a diagnostic message for the latest result. The app checks at launch, every five minutes, and whenever **Recheck now** is selected.

## How detection works

The two signals are intentionally independent:

1. **Google connectivity** — requests `https://www.google.com/generate_204`. A valid result must return HTTP 204 and finish on `google.com` or a real subdomain of it.
2. **Exit-country estimate** — after Google succeeds, requests Cloudflare's public [`/cdn-cgi/trace`](https://developers.cloudflare.com/fundamentals/reference/cdn-cgi-endpoint/) endpoint and reads its two-letter `loc` field.

[Google is moving country-specific Search domains toward `google.com`](https://blog.google/products-and-platforms/products/search/country-code-top-level-domains/), so the landing domain is no longer a reliable country signal. Missing or malformed region data is reported as **unknown** instead of being treated as US.

The country result is an estimate of the path to Cloudflare. A domain-based proxy rule or split tunnel can route Google and Cloudflare differently; in that configuration, the displayed country may not describe Google's exact path.

## Privacy and networking

- The app sends no telemetry of its own and stores no history or preferences.
- Requests use HTTPS, an ephemeral `URLSession`, no cookies, and no response cache.
- A successful check contacts both Google and Cloudflare. Cloudflare can observe the request IP and the app's User-Agent, as with any direct HTTPS request.
- A failed Google check does not contact Cloudflare.

## Requirements

- macOS 11.0 or later
- Apple Silicon by default; universal builds are supported
- Xcode Command Line Tools matching the installed macOS SDK

## Build and run

```bash
./build.sh
open GoogleStatusChecker.app
```

The default output is an ad-hoc-signed arm64 app. Build a universal app or change the minimum OS with environment variables:

```bash
ARCHS="arm64 x86_64" ./build.sh
MIN_OS=13.0 ./build.sh
```

`MIN_OS` is applied to both the binary target and the generated app's `Info.plist`.

Run the classifier tests with:

```bash
./test.sh
```

## Usage

The app runs only in the menu bar and does not appear in the Dock.

| Menu item | Action |
| :--- | :--- |
| Status / diagnostic / last check | Shows the current result and reason |
| Recheck now (`⌘R`) | Runs a check immediately |
| Open Google (`⌘O`) | Opens Google in the default browser |
| Quit (`⌘Q`) | Quits the app |

To launch it at login, add `GoogleStatusChecker.app` in **System Settings → General → Login Items & Extensions**.

## Sharing the app

Ad-hoc signing is intended for local builds. A copied app may be blocked by Gatekeeper because it is not Developer ID signed or notarized.

```bash
zip -r -X GoogleStatusChecker.zip GoogleStatusChecker.app
```

On a trusted target Mac, remove the downloaded quarantine attribute and use **right-click → Open** for the first launch:

```bash
xattr -cr /path/to/GoogleStatusChecker.app
open /path/to/GoogleStatusChecker.app
```

For public distribution, use an Apple Developer ID certificate and notarization instead of asking users to bypass quarantine.

## Project structure

```text
GoogleStatusChecker/
├── CheckerCore.swift             # Pure host, response, and country classification
├── main.swift                    # Networking and AppKit menu-bar UI
├── Tests/CheckerCoreTests.swift  # Offline classifier tests
├── Info.plist                    # App bundle metadata
├── build.sh                      # Build, package, and ad-hoc sign
└── test.sh                       # Compile and run tests
```

## License

MIT License © 2026 tiansi
