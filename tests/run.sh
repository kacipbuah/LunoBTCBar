#!/bin/bash
# Compile the price logic with the test runner and execute it.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
swiftc -swift-version 5 -o "$OUT/tests" PriceHistory.swift tests/main.swift
"$OUT/tests"
