#!/bin/zsh
# Run the pure pricing-rule tests without launching the UI.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/build"

swiftc -O -target arm64-apple-macos13.0 \
  -o "$ROOT/build/PricingTests" \
  "$ROOT/Sources/Pricing.swift" "$ROOT/Sources/TokenURL.swift" "$ROOT/Sources/Updates.swift" \
  "$ROOT/Tests/main.swift"

"$ROOT/build/PricingTests"
