# Harness Desk

[![build](https://github.com/NaleenB/harness-desk-macos/actions/workflows/ci.yml/badge.svg)](https://github.com/NaleenB/harness-desk-macos/actions/workflows/ci.yml)

A small, native macOS launcher for [DeepSeek Harness](https://deepseek-harness.github.io/deepseek-harness/).

It is a single Swift file wrapped around `WKWebView`. It starts the local
`dsh web` server (or attaches to one that is already running), waits for the
authenticated URL, and loads the normal Harness UI in a native window. No
Electron, no bundled runtime, no extra copy of `dsh`.

> **Unofficial.** This project is not affiliated with or endorsed by DeepSeek.
> It is a community shell around the open-source Harness Web UI.

## Status

Source-first. There are no prebuilt binaries in this repository: build it
locally with the Xcode Command Line Tools. The build script ad-hoc signs the
result for local use; public distribution needs a Developer ID and
notarization (see [SECURITY.md](SECURITY.md)).

## Why another launcher?

The official desktop app is Electron and, at the time of writing, has no release
assets. Generic "web app" wrappers also miss the part that matters here: they
do not start, attach to, or restart `dsh web`, and they do not handle the
per-process launch token and port-bound cookie. Harness Desk is deliberately
small and does only that.

- Native AppKit/WebKit window, ~200 KB binary (plus the system WebKit runtime).
- Uses the `dsh` you already installed, so it never runs a stale bundled copy.
- Attaches to a running server instead of starting a second one; one launcher
  instance per user.
- Health-checks the server and restarts it with 1/2/4-second backoff, reloading
  the same window with the new token.
- Handles the WebKit details the UI needs: OAuth/sign-in popups, microphone
  capture, tokenised "Open in Browser", and ⌘W.
- Stores the launch token and launcher log with `0600` permissions and redacts
  the token from logs.
- A subtle title-bar pricing indicator (Peak/Normal) based on the UTC weekday
  windows and the current system timezone; hover for the schedule, local time,
  and a countdown to the end of the current period.
- **About Harness Desk** (App menu, or **Check for Updates…**) shows the
  installed Harness Desk and DeepSeek Harness versions, checks the npm `latest`
  tag and the latest GitHub release on demand, lists the `next` and `alpha`
  pre-release channels, and copies the update command. It only makes those two
  requests while the window is open, and it never installs anything itself.

## Requirements

- macOS 13 or newer (arm64 build by default).
- Xcode Command Line Tools: `xcode-select --install`.
- DeepSeek Harness installed as `dsh`:

  ```sh
  npm install -g --allow-scripts=@deepseek-ai/dsh-subprocess-local,koffi,node-pty,@google/genai,protobufjs @deepseek-ai/dsh
  ```

  See the [DeepSeek Harness docs](https://deepseek-harness.github.io/deepseek-harness/)
  for the current install instructions and model setup.

## Build and run

```sh
git clone https://github.com/NaleenB/harness-desk-macos.git
cd harness-desk-macos
./scripts/build.sh --install
open "/Applications/HarnessDesk.app"
```

`--install` is optional; without it the app is built at
`build/HarnessDesk.app` and not copied anywhere. The unit tests (pricing
windows, version ordering, token parsing) run with `./scripts/test.sh`.

The build script uses `swiftc`, writes the bundle, injects the app identity into
`Resources/Info.plist.in`, ad-hoc signs the result, and copies it to
`$INSTALL_DIR` when asked. Override the identity with environment variables:

```sh
DISPLAY_NAME="Harness Desk" \
BUNDLE_ID="dev.example.harnessdesk" \
VERSION="0.1.0" \
INSTALL_DIR="$HOME/Applications" \
./scripts/build.sh --install
```

## How it works

1. Refuse to start if another copy of the app is already running.
2. Probe `3080–3090` for a live DSH server (identified by its `401 dsh web
   authentication required` response). If one is found, validate the saved
   token with a throwaway cookie jar and attach; otherwise fall back to the
   WebView cookie for that port.
3. If there is no server, pick the first free port and run
   `dsh web --no-open --port <n>` from the workspace, scrape the
   `dsh web: http://127.0.0.1:<port>/?token=…` line, and load it.
4. Write the tokenised URL to `~/.dsh/web-ui-url.txt` (mode `0600`) and load it
   in a `WKWebView`, which receives the 30-day signed cookie.
5. Every 5 seconds, check the port. Two misses trigger a restart with 1/2/4
   second backoff (three attempts); the same WebView reloads the new token.
   `⌘Q` stops a server the app started; an attached server is left running.

## Configuration

Environment variables read by the app:

| Variable | Default | Purpose |
|---|---|---|
| `DSH_WEB_WORKSPACE` | first of `~/Projects`, `~/Developer`, `~/coding_projects`, then `~` | Working directory for `dsh web` |
| `DSH_LAUNCHER_PORT_START` | `3080` | First port to scan/use |
| `DSH_LAUNCHER_PORT_END` | `3090` | Last port to scan/use |
| `DSH_LAUNCHER_INSPECTABLE` | unset | Set to `1` to make the WebView inspectable from Safari |

Build-time variables: `APP_NAME`, `DISPLAY_NAME`, `BUNDLE_ID`, `VERSION`,
`BUILD_NUMBER`, `INSTALL_DIR`, `ICON_PATH` (an optional `.icns` for personal
builds; the repository default is a neutral icon).

## Security

Harness Desk runs with your user privileges and starts `dsh`, which can execute
commands and read `~/.dsh` (credentials, sessions). Treat it as trusted local
code, build it from source, and read the code before running it. It has no
telemetry. Its only network requests are the two update checks behind **About
Harness Desk** (npm registry and GitHub), which run only while that window is
open.

The launch token is a live credential for the running server. It is written to
`~/.dsh/web-ui-url.txt` with mode `0600`, and the launcher log redacts it. The
token rotates whenever `dsh web` starts.

The build script ad-hoc signs the app. That is fine for this Mac; Gatekeeper
will reject it on another Mac. If you distribute a binary, use a Developer ID,
the hardened runtime, and notarization. See [SECURITY.md](SECURITY.md).

## Known limitations

- macOS only, arm64 by default. Change `-target` in `scripts/build.sh` for
  Intel or a universal build.
- The startup URL is parsed from the `dsh web:` stdout line. An upstream change
  to that line will make the launcher retry and eventually show an alert until
  it is updated.
- No auto-update: the About window reports newer versions and copies the
  command to install them, but nothing updates itself.
- No preferences window, native file dialogs, downloads, notifications, or
  multi-window support.
- Attaching to a server the app did not start means `⌘Q` leaves that server
  running. Stop it with `pkill -f "dsh web"` if needed.
- Rebuilding changes the ad-hoc signature; macOS may ask for microphone access
  again.
- The pricing indicator follows the weekday UTC windows only; Chinese public
  holidays are not included.
- Account profile/balance calls can log `403` from `platform.deepseek.com`.
  That endpoint is behind AWS WAF; the browser's `aws-waf-token` cookie is not
  sent by the host process. The model path through the API key is unaffected.

## Troubleshooting

- **Sign-in shows "There is no application set to open the URL about:blank"** —
  this build is too old to support popups. Rebuild from this repository.
- **"This browser cannot record audio"** — the bundle is missing
  `NSMicrophoneUsageDescription`; rebuild. If it says microphone access is
  disabled, allow Harness Desk in System Settings → Privacy & Security →
  Microphone.
- **"Harness authentication required"** — a DSH server is running but this app
  has no valid token or cookie for its port (for example, it was started in a
  terminal). Quit it with `pkill -f "dsh web"` and reopen, or open its printed
  token URL in a browser.
- **Ports 3080–3090 occupied** — another service holds them. The launcher skips
  non-DSH ports; change `DSH_LAUNCHER_PORT_START`/`END` if needed.
- **Logs** — `~/.dsh/logs/web-launcher.log`.

## Compatibility

Tested with `dsh 0.2.1-rc.2` on macOS 27.0.1. DeepSeek Harness is a developer
preview; its CLI output and plugin config can change between rc releases. If
the launcher breaks after an upgrade, check the log and open an issue.

## License

MIT. See [LICENSE](LICENSE). DeepSeek Harness is a separate project under its
own license.
