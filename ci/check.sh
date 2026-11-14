#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
zig fmt --check build.zig src tests/consumer
for mode in Debug ReleaseSafe; do
    timeout 120s zig build test test-integration test-networkmanager test-bluez example-networkmanager example-bluez -Doptimize="$mode" --summary all
done
python3 ci/check-consumer.py
