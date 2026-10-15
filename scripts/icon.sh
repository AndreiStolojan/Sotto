#!/bin/bash
# Render the design/ SVGs into the app icon, the Sotto Beta icon and the menu bar icon assets.
# Needs rsvg-convert (brew install librsvg) and python3.
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
command -v rsvg-convert >/dev/null || { echo "Missing rsvg-convert: brew install librsvg" >&2; exit 1; }
assets="$repo_dir/Voce/Assets.xcassets"
beta_svg="$(mktemp -t sotto-beta-icon).svg"
trap 'rm -f "$beta_svg"' EXIT

# Sotto Beta keeps the same artwork, with the light dots tinted the app's teal accent (#66D6BF).
python3 - "$repo_dir/design/Voce-icon.svg" "$beta_svg" <<'EOF'
import re, sys
teal = (0x66, 0xD6, 0xBF)
def tint(match):
    rgb = [int(match.group(2)[i:i + 2], 16) for i in (0, 2, 4)]
    light = sum(rgb) / (3 * 255)
    return match.group(1) + 'fill="#%02x%02x%02x"' % tuple(round(c * light) for c in teal)
svg = open(sys.argv[1]).read()
# Only the dots: circles with a six-digit fill. The background and shadow stay as they are.
svg = re.sub(r'(<circle [^>]*?)fill="#([0-9a-f]{6})"', tint, svg)
open(sys.argv[2], "w").write(svg)
EOF

for size in 16 32 64 128 256 512 1024; do
    rsvg-convert -w "$size" -h "$size" "$repo_dir/design/Voce-icon.svg" -o "$assets/AppIcon.appiconset/$size-mac.png"
    rsvg-convert -w "$size" -h "$size" "$beta_svg" -o "$assets/AppIconBeta.appiconset/$size-mac.png"
done
# Shown 22 pt tall as a template image; 6x keeps it sharp on any display.
rsvg-convert -w 132 -h 132 "$repo_dir/design/Voce-menu-bar.svg" -o "$assets/menuBarIcon.imageset/menuBarIcon.png"
echo "Wrote AppIcon, AppIconBeta and menuBarIcon assets"
