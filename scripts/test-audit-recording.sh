#!/usr/bin/env bash
# Compile the History CSV field encoder alone, check it, and confirm Python's csv module
# (used by scripts/benchmark.py) reads every exported value back unchanged.
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/voce-audit-recording.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
cd "$repo_dir"

swiftc -parse-as-library -module-cache-path "$test_dir/ModuleCache" \
    Voce/Features/History/Export/CSVField.swift \
    Tests/AuditRecording/CSVFieldTests.swift \
    -o "$test_dir/csv-field-tests"
"$test_dir/csv-field-tests"

"$test_dir/csv-field-tests" --emit > "$test_dir/sample.csv"
python3 -I - "$test_dir/sample.csv" <<'PY'
import csv, sys
expected = ["plain", 'say "hi"', "a,b", "line\nbreak", "carriage\rreturn", "crlf\r\nend",
            "=SUM(A1:A2)", "+1 and -2 @home", "Nu șterge raport.csv.", ""]
with open(sys.argv[1], encoding="utf-8", newline="") as source:
    rows = list(csv.DictReader(source, strict=True))
values = [rows[0][f"c{i}"] for i in range(len(expected))] if len(rows) == 1 else None
if values != expected:
    sys.exit(f"FAIL: csv round trip changed values: {values!r}")
print("PASS: Python csv reads every exported value literally")
PY
