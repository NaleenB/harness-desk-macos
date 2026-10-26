# Security policy

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting for this repository
(Security → Report a vulnerability). Do not open a public issue that contains
tokens, API keys, session data, or a working exploit. If private reporting is
not enabled, open a minimal issue asking for a private channel; do not include
the details there.

This launcher starts a local `dsh` server and reads `~/.dsh`; bugs that let a
remote page reach those privileges are in scope. Bugs in DeepSeek Harness
itself (the `dsh` CLI, its web server, or its plugins) should be reported to the
upstream project instead.

## Threat model

- The app runs with the logged-in user's privileges.
- `dsh` can execute shell commands and read `~/.dsh/.credentials.yaml` and
  session data. The launcher does not add a sandbox around it.
- The only network listener is the harness itself on `127.0.0.1`.
- The launcher makes no telemetry or third-party network requests.
- The launch token in `~/.dsh/web-ui-url.txt` grants control of the running
  server. It is written with mode `0600`; the log redacts it.
- Ad-hoc builds are local-only. Distributing a binary requires a Developer ID,
  hardened runtime, and notarization.

## Release policy

There are currently no prebuilt binaries. If releases are added, they should be
signed, notarized, and accompanied by a checksum and the exact source revision.
Do not ask users to strip quarantine attributes from a downloaded app.
