# GoogleStatusChecker

A small macOS menu-bar app that checks whether Google, ChatGPT (OpenAI), and Claude (Anthropic) are reachable through a United States network exit. Each bar also checks the login and service endpoints used by Antigravity, Codex, or Claude Code. Green requires a US country signal and successful checks for every critical endpoint.

## Three-service status icon

The status icon shows three rounded vertical bars arranged as a compact square. Their fixed left-to-right order is:

1. **Google**
2. **ChatGPT**
3. **Claude**

Each bar changes independently, so one service can remain green while another is yellow, red, blue, or checking. The menu also shows an overall summary and a diagnostic message for every service:

| Per-service symbol | Meaning |
| :---: | :--- |
| 🟢 US exit | The web and required agent checks passed, and the country signal is `US` |
| 🟡 Non-US / restricted | The country signal is not `US`, or the API rejects the request |
| 🔴 Unavailable | Connection failed, or the IP was blocked/challenged by Cloudflare |
| 🔵 Unknown | Reachable, but the exit country could not be confirmed; unknown is never treated as green |

The app checks at launch, every five minutes, and whenever **Recheck now** (`⌘R`) is selected. The three services are probed in parallel.

### Exit IP changes

Google and ChatGPT pulse when their last confirmed address changes. Claude keeps separate IPv4 and IPv6 baselines. The first address in each family establishes its baseline. Switching between the two known addresses is recorded in the report, and replacing either baseline triggers a reminder. On upgrade, Claude recovers the most recent address of each family from the saved history. With macOS Reduce Motion enabled, reminders use a steady highlight. A failed or incomplete IP reading preserves the last confirmed addresses.

Click the flashing icon to see the **出口 IP 变化报告** and clear the highlights. The report shows the last confirmed IP, observation time, and source for each service, followed by changes with their detection time and old and new addresses. Right-clicking the icon opens the regular menu, where the report is always available.

ChatGPT and Claude use the IP seen by their respective web domains. The Google bar uses the IP seen by `www.cloudflare.com` as an estimate. Domain-based proxy rules can route Google through a different exit.

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

### Agent endpoints and Clash rules

Open a service’s submenu to see each address, its purpose, HTTP status or connection error. Hover over an entry for its method and full URL. A failed critical check changes that service’s bar even if the website and region checks passed. Auxiliary entries cover assets, optional features, and other Clash rule destinations. Their results are visible individually.

| Agent | Critical checks | Auxiliary examples |
| --- | --- | --- |
| Google Antigravity (personal Google account) | Google sign-in discovery, OAuth token service, daily Cloud Code model service, HTTPS to the client configuration host | Cloud Code, Gemini API-key mode, enterprise orchestration, Vertex AI and Discovery Engine |
| OpenAI Codex | OpenAI sign-in discovery and token service, ChatGPT subscription Responses endpoint, public Responses API | File and static hosts, login challenges and representative hosts for the remaining OpenAI provider suffixes |
| Claude Code | Browser sign-in redirect, OAuth client metadata, OAuth token exchange, Messages API | SSO, MCP, downloads and the Chrome extension bridge |

The app checks the addresses in its bundled [agent endpoint catalog](Resources/AgentEndpoints.json) using the Mac’s active routing. The checked Clash profile assigns the OpenAI and Claude rule providers to `Ai+` and the Google provider to `Google`. The Claude provider only lists `anthropic.com` and `claude.ai`. Additional agent domains such as `platform.claude.com` follow whichever other rule matches on the machine. The bundled list represents the reviewed rules and does not automatically synchronize with subscription updates.

Probes use public metadata, an expected redirect, or an empty request to a protected endpoint. A recognized authentication or missing-parameter response confirms the endpoint answered. Host-only entries report the first HTTPS response, including its status. These checks use no account credentials or model prompts. Per-service IP history continues to use the web trace or Google’s auxiliary trace, which may use a different route from an agent endpoint.

Endpoint references include [Codex authentication](https://developers.openai.com/codex/auth/), [Claude Code network requirements](https://code.claude.com/docs/en/network-config), [Antigravity personal account endpoints](https://discuss.ai.google.dev/t/antigravity-2-26-0-macos-sign-in-fails-loadcodeassist-socket-is-not-connected/195017), and [Antigravity enterprise networking](https://antigravity.google/docs/enterprise).

## Privacy and networking

- The app stores the last confirmed IP, observation time, unread reminders, and up to 50 changes per service locally. This history survives relaunches. The app sends no telemetry.
- Requests use HTTPS and an ephemeral `URLSession` with cookies and response caching disabled. No API keys are used or required.
- A full check contacts the web and region hosts above and the agent and auxiliary endpoints in the bundled list. Each destination can observe the request IP and User-Agent.
- Agent probes run independently of the web checks, with at most four concurrent agent requests per service. A failed web probe still skips its dependent follow-up.

## macOS requirements

- macOS 11.0 or later
- Apple Silicon by default; universal builds are supported
- Xcode Command Line Tools matching the installed macOS SDK

## Build and run on macOS

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

## macOS usage

The app runs only in the menu bar and does not appear in the Dock.

| Menu item | Action |
| :--- | :--- |
| Status | Overall light and per-service state + diagnostic for each |
| 查看出口 IP 变化报告… | Shows the latest confirmed IPs and change history |
| Recheck now (`⌘R`) | Runs a check immediately |
| Open Google (`⌘O`) / ChatGPT (`⌘G`) / Claude (`⌘L`) | Opens the service in the default browser |
| Quit (`⌘Q`) | Quits the app |

To launch it at login, add `GoogleStatusChecker.app` in **System Settings → General → Login Items & Extensions**.

## Sharing the macOS app

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
├── Resources/AgentEndpoints.json # Bundled agent endpoint catalog
├── AgentProbes.swift             # Expected agent responses and bar aggregation
├── ExitIPHistory.swift           # Per-service IP observations and local history
├── IPReportWindow.swift          # Native IP change report window
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
