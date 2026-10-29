# Changelog

## 0.1.5 — 2026-10-29

- Add an About window (App menu → About Harness Desk, or Check for Updates…).
  It shows the installed Harness Desk and DeepSeek Harness versions, checks the
  npm `latest` tag and the latest GitHub release on demand, lists the `next` and
  `alpha` pre-release channels, and copies the update command. Nothing is
  checked in the background and nothing installs itself.
- Version ordering follows semver, so `0.2.1-rc.4` sorts above `0.2.1-rc.2` and
  below `0.2.2-alpha.2`; covered by the unit tests.

## 0.1.4 — 2026-10-27

- Fix the pricing tooltip appearing only over part of the badge, or being
  dismissed by the 30-second refresh. The dot and text are now one view with a
  single, stable tooltip registration, and VoiceOver reads the same text.

## 0.1.3 — 2026-10-26

- The pricing tooltip now counts down to the end of the current period, e.g.
  "Peak period ends in 2h 31m". Weekends show days as well ("2d 13h 5m").

## 0.1.2 — 2026-10-26

- Add a subtle title-bar pricing indicator (Peak/Normal) for the official
  DeepSeek API. It follows the UTC weekday windows and the system timezone;
  hover for the schedule and local time. Chinese public holidays are not included.

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
