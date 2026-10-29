#!/usr/bin/env bash
# Compile and run the provider audit tests.
# The Core ML archive tests are portable (macOS or a Linux Swift toolchain). The ProcessRunner and
# deflated-archive tests need macOS (/usr/bin/zip, python3) and run only there.
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/voce-provider-audit-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
cd "$repo_dir"

if [[ "$(uname)" == "Darwin" ]]; then
    swiftc=(xcrun swiftc)
else
    swiftc=(swiftc)
fi

"${swiftc[@]}" -parse-as-library -module-cache-path "$test_dir/ModuleCache" \
    Voce/Features/ModelLibrary/State/WhisperCoreMLArchive.swift \
    Tests/AuditProviders/CoreMLArchiveTests.swift \
    -o "$test_dir/coreml-archive-tests"
"$test_dir/coreml-archive-tests"

if [[ "$(uname)" == "Darwin" ]]; then
    "${swiftc[@]}" -parse-as-library -module-cache-path "$test_dir/ModuleCache" \
        Voce/Infrastructure/SystemIntegration/Processes/ProcessRunner.swift \
        Voce/Features/ModelLibrary/State/WhisperCoreMLArchive.swift \
        Tests/AuditProviders/ProviderAuditTests.swift \
        -o "$test_dir/provider-audit-tests"
    "$test_dir/provider-audit-tests"
fi
