#!/usr/bin/env bash
# Compile the production settings bounds with their focused checks and run them.
# Needs only Foundation, so it runs on macOS (xcrun swiftc) and Linux (swiftc).
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/voce-audit-persistence.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
cd "$repo_dir"

if command -v xcrun >/dev/null 2>&1; then swiftc=(xcrun swiftc); else swiftc=(swiftc); fi

"${swiftc[@]}" -parse-as-library -module-cache-path "$test_dir/module-cache" \
    Voce/App/Configuration/SettingsValueLimits.swift \
    Tests/AuditPersistence/SettingsValueLimitsTests.swift \
    -o "$test_dir/audit-persistence-tests"
"$test_dir/audit-persistence-tests"
