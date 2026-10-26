# Changelog

## 0.1.1 — 2026-10-26

- Fix attach detection for GUI launches: probe the harness with a raw loopback
  HTTP request instead of `URLSession`, which can be blocked by macOS local
  network policy. The saved token is now validated by the WebView itself.

## 0.1.0 — 2026-10-26

- Initial native macOS launcher for DeepSeek Harness.
- Starts, attaches to, and health-checks `dsh web`; single-instance guard;
  1/2/4-second restart backoff that reloads the same window.
- Handles sign-in popups, microphone capture, tokenised Open in Browser, ⌘W,
  and zoom.
- Writes the launch token and launcher log with `0600` permissions and redacts
  the token from logs.
- Configurable workspace, port range, app name, bundle id, and install
  directory.
