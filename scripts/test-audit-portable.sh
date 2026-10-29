#!/usr/bin/env bash
# Exercise production website matching, recording ownership and Auto Learn JSON recovery.
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/sotto-portable-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
cd "$repo_dir"
swiftc -swift-version 5 -parse-as-library -module-cache-path "$test_dir/ModuleCache" \
    Voce/App/Configuration/AppStorageNamespace.swift \
    Voce/Features/Modes/State/ModeWebsiteMatcher.swift \
    Voce/Infrastructure/Persistence/Cleanup/RecordingFileLocation.swift \
    Voce/Features/Dictionary/AutoLearn/AutoLearnJSONArrayFile.swift \
    Tests/AuditPortable/RulesTests.swift \
    -o "$test_dir/rules-tests"
"$test_dir/rules-tests" "$test_dir"
