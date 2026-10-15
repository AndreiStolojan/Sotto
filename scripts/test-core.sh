#!/usr/bin/env bash
# Compile the production audio, transcript, language policy, session policy and Eclipse protocol code without launching the app.
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/voce-core-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
cd "$repo_dir"

# MarkdownUI loads image URLs by default. Only MarkdownContentView may create Markdown views,
# and it must replace both image providers.
markdown_users="$(grep -rl --include='*.swift' -E '(^|[^A-Za-z])Markdown\(' Voce | grep -v 'MarkdownContentView.swift' || true)"
[[ -z "$markdown_users" ]] || { echo "FAIL: Markdown views outside MarkdownContentView: $markdown_users" >&2; exit 1; }
for provider in markdownImageProvider markdownInlineImageProvider; do
    grep -q "\.$provider(No" Voce/DesignSystem/Components/MarkdownContentView.swift ||
        { echo "FAIL: MarkdownContentView must set $provider" >&2; exit 1; }
done
echo "PASS: Markdown never loads remote images"

xcrun swiftc -D VOCE_LOCAL -parse-as-library \
    Voce/Infrastructure/Audio/PCMAudioConverter.swift \
    Voce/Infrastructure/SystemIntegration/Lifecycle/UserSessionInputPolicy.swift \
    Voce/Infrastructure/TextProcessing/ParagraphFormatter.swift \
    Voce/Infrastructure/TextProcessing/WordCounter.swift \
    Voce/Features/ModelLibrary/Models/LanguageDictionary.swift \
    Voce/Features/ModelLibrary/Models/TranscriptionModel.swift \
    Voce/Features/ModelLibrary/Models/TranscriptionModelRegistry.swift \
    Voce/Core/Recording/RecordingState.swift \
    Voce/Features/Recording/Presentation/NotchSocket.swift \
    Tests/CI/CoreTests.swift \
    -o "$test_dir/core-tests"
"$test_dir/core-tests"
