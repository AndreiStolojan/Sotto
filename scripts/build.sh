#!/bin/bash
# Build Sotto (or Sotto Beta) in Release from this checkout. Prints the built app's path on the last line.
# install.sh and CI both call this; run it yourself to build without installing.
#
# Usage: scripts/build.sh [--beta]
# Environment:
#   SOTTO_CODESIGN_IDENTITY  optional signing identity (name or SHA-1) for the finished app.
#                            Without it the app is ad-hoc signed.
set -euo pipefail

channel=stable
case "${1:-}" in
    "") ;;
    --beta) channel=beta ;;
    -h|--help)
        sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
        exit 0 ;;
    *) echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
esac

[[ "$(uname -s)" == Darwin ]] || { echo "Sotto builds on macOS only." >&2; exit 1; }
xcodebuild -version >/dev/null 2>&1 || {
    echo "Full Xcode is required; the Command Line Tools alone cannot build Sotto." >&2
    exit 1
}
for tool in curl shasum ditto codesign; do
    command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$repo_dir/.build"
deps_dir="$build_dir/deps"
derived_dir="$build_dir/$channel"

if [[ "$channel" == beta ]]; then
    app_name="Sotto Beta"
    bundle_suffix=.beta
    name_suffix=" Beta"
    icon_name=AppIconBeta
else
    app_name=Sotto
    bundle_suffix=
    name_suffix=
    icon_name=AppIcon
fi

# whisper.cpp ships as a prebuilt XCFramework. Pin the official release and check its hash.
# The project's VOCE_WHISPER_XCFRAMEWORK setting expects it at .build/deps/whisper-<version>.
whisper_version=v1.8.2
whisper_sha256=3ffeec1df254d908f01ee3d87bf0aedb8fbc8f29cbf50dc8702741bb85381385
whisper_dir="$deps_dir/whisper-$whisper_version"
framework_path="$whisper_dir/whisper.xcframework"
stage=
trap '[[ -z "$stage" ]] || rm -rf "$stage"' EXIT

if [[ ! -f "$framework_path/Info.plist" ]]; then
    mkdir -p "$deps_dir"
    rm -rf "$whisper_dir"
    stage="$(mktemp -d "$deps_dir/.whisper.XXXXXX")"
    echo "==> Downloading whisper.cpp $whisper_version XCFramework"
    curl --fail --location --retry 3 --proto '=https' --proto-redir '=https' --progress-bar \
        --output "$stage/source.zip" \
        "https://github.com/ggml-org/whisper.cpp/releases/download/$whisper_version/whisper-$whisper_version-xcframework.zip"
    if [[ "$(shasum -a 256 "$stage/source.zip" | awk '{print $1}')" != "$whisper_sha256" ]]; then
        echo "The whisper.cpp download does not match the pinned SHA-256." >&2
        exit 1
    fi
    ditto -x -k "$stage/source.zip" "$stage/unpacked"
    mkdir -p "$whisper_dir"
    mv "$stage/unpacked/build-apple/whisper.xcframework" "$framework_path"
fi

echo "==> Building $app_name (Release, $(uname -m)). The first build takes several minutes."
echo "    Warnings from dependencies such as FluidAudio are expected."
cd "$repo_dir"
# The project signs ad-hoc ("Sign to Run Locally"), so no Apple developer team is needed.
# APP_BUNDLE_ID_SUFFIX, APP_NAME_SUFFIX and APP_ICON_NAME turn the same target into Sotto Beta.
xcodebuild -project Voce.xcodeproj -scheme Voce -configuration Release \
    -derivedDataPath "$derived_dir" \
    -clonedSourcePackagesDirPath "$deps_dir/SourcePackages" \
    -onlyUsePackageVersionsFromResolvedFile \
    -skipPackagePluginValidation -skipMacroValidation \
    ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO \
    APP_BUNDLE_ID_SUFFIX="$bundle_suffix" APP_NAME_SUFFIX="$name_suffix" APP_ICON_NAME="$icon_name" \
    -quiet build

app_path="$derived_dir/Build/Products/Release/$app_name.app"
[[ -d "$app_path" ]] || { echo "Build finished without the expected app: $app_path" >&2; exit 1; }

# A real certificate gives the app a stable identity, so macOS keeps its permissions across rebuilds.
# Only the outer app is re-signed; Xcode already signed the nested parts ad-hoc.
if [[ -n "${SOTTO_CODESIGN_IDENTITY:-}" ]]; then
    echo "==> Signing with $SOTTO_CODESIGN_IDENTITY"
    codesign --force --sign "$SOTTO_CODESIGN_IDENTITY" --timestamp=none \
        --preserve-metadata=identifier,entitlements,flags "$app_path"
fi
codesign --verify --deep --strict "$app_path"

# Shipping the app means shipping its third-party license texts (scripts/third-party-licenses.py).
[[ -f "$app_path/Contents/Resources/THIRD_PARTY_LICENSES.md" ]] ||
    { echo "Refusing this build: THIRD_PARTY_LICENSES.md is missing from the app." >&2; exit 1; }

# get-task-allow lets other processes attach a debugger. A Release build must never carry it.
while IFS= read -r -d '' code; do
    if codesign -d --entitlements - --xml "$code" 2>/dev/null | grep -q get-task-allow; then
        echo "Refusing this build: $code carries the get-task-allow entitlement." >&2
        exit 1
    fi
done < <(find "$app_path" \( -type f -perm -u+x -o -name '*.framework' -o -name '*.dylib' -o -name '*.xpc' \) -print0)
echo "$app_path"
