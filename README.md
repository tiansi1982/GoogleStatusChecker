# GoogleStatusChecker

A small macOS menu-bar app that checks whether Google, ChatGPT (OpenAI), and Claude (Anthropic) are reachable through a United States network exit. A green overall light is shown only when every service is reachable and every available country signal is `US`.

## Three-service status icon

The menu bar shows three rounded vertical bars arranged as a compact square. Their fixed left-to-right order is:

1. **Google**
2. **ChatGPT**
3. **Claude**

Each bar changes independently, so one service can remain green while another is yellow, red, blue, or checking. The menu also shows an overall summary and a diagnostic message for every service:

| Per-service symbol | Meaning |
| :---: | :--- |
| 🟢 US exit | The service and its auxiliary API probe are reachable, and the country signal is `US` |
| 🟡 Non-US / restricted | The country signal is not `US`, or the API rejects the request |
| 🔴 Unavailable | Connection failed, or the IP was blocked/challenged by Cloudflare |
| 🔵 Unknown | Reachable, but the exit country could not be confirmed; unknown is never treated as green |

The app checks at launch, every five minutes, and whenever **Recheck now** (`⌘R`) is selected. The three services are probed in parallel.

## How detection works

1. **Google** — requests `https://www.google.com/generate_204` (must return HTTP 204 on a real `google.com` host), then reads the `loc` field of Cloudflare's [`/cdn-cgi/trace`](https://developers.cloudflare.com/fundamentals/reference/cdn-cgi-endpoint/) endpoint as an auxiliary estimate of the machine's exit country. Green requires `US`; any other country is yellow, and missing data is unknown.
2. **ChatGPT** — requests `https://chatgpt.com/cdn-cgi/trace` for a service-specific country signal, then calls `https://api.openai.com/v1/models` **without credentials** as an auxiliary reachability/region-rejection probe:
   - `401` JSON error → the API entry point answered and did not reject this unauthenticated request
   - `403` with `unsupported_country_region_territory` → OpenAI does not support the exit region
   - `403` with a Cloudflare block/challenge page → the IP is flagged
3. **Claude** — requests `https://claude.ai/cdn-cgi/trace` for its country signal, then calls `https://api.anthropic.com/v1/models` **without credentials** as an auxiliary probe (`401` `authentication_error` → API entry point reachable; `403` → region/permission restricted or blocked).

For ChatGPT and Claude, an expected API authentication error is not enough for green: their `cdn-cgi/trace` country must also be `US`. A non-US or missing country signal always prevents an overall green light.

[Google is moving country-specific Search domains toward `google.com`](https://blog.google/products-and-platforms/products/search/country-code-top-level-domains/), so the landing domain is no longer a reliable country signal. Missing or malformed region data is reported as **unknown** instead of being treated as US.

ChatGPT and Claude use trace endpoints on their own service domains, so domain-based proxy differences are visible. Google does not expose an equivalent stable country endpoint: its country is estimated through a separate Cloudflare request. If proxy rules route `google.com` and `cloudflare.com` differently, the Google country estimate cannot prove the exact Google path; the menu labels this signal as a Cloudflare-assisted estimate.

## Privacy and networking

- The app sends no telemetry of its own and stores no history or preferences.
- Requests use HTTPS, an ephemeral `URLSession`, no cookies, and no response cache. No API keys are used or required.
- A full check contacts `google.com`, `cloudflare.com`, `chatgpt.com`, `api.openai.com`, `claude.ai`, and `api.anthropic.com`. These services can observe the request IP and the app's User-Agent, as with any direct HTTPS request.
- A failed probe does not trigger its dependent follow-up request.

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
| Status | Overall light and per-service state + diagnostic for each |
| Recheck now (`⌘R`) | Runs a check immediately |
| Open Google (`⌘O`) / ChatGPT (`⌘G`) / Claude (`⌘L`) | Opens the service in the default browser |
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
├── CheckerCore.swift             # Pure host, response, region, and aggregation classifiers
├── main.swift                    # Networking and AppKit menu-bar UI
├── Tests/CheckerCoreTests.swift  # Offline classifier tests
├── Info.plist                    # App bundle metadata
├── AppIcon.icns                  # App icon (generated by make-icon.sh)
├── make_icon.swift               # Renders the icon artwork
├── make-icon.sh                  # Builds AppIcon.icns
├── build.sh                      # Build, package, and ad-hoc sign
└── test.sh                       # Compile and run tests
```

Regenerate the app icon with `./make-icon.sh`, then rebuild with `./build.sh`.

## License

MIT License © 2026 tiansi
