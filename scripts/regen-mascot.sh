#!/usr/bin/env bash
# Regenerate mascot PNGs from SVG sources using librsvg's rsvg-convert.
#
# Multi-species: SVG sources live under assets/mascot/<species>/ and each frame
# is rendered to the asset catalog at watchCat/Assets.xcassets/<species>-<frame>.imageset/.
# The "<species>-<frame>" naming gives every mascot its own asset key so
# `NSImage(named:)` can pick by user preference at runtime.
#
# Why rsvg-convert and not sips/qlmanage: qlmanage flattens alpha against an
# opaque white background, which made the 22pt mascot render as a solid white
# square in the menu bar. rsvg-convert preserves transparency.
#
# Requires: librsvg (brew install librsvg)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="${REPO_ROOT}/assets/mascot"
DST_DIR="${REPO_ROOT}/watchCat/Assets.xcassets"

if ! command -v rsvg-convert >/dev/null 2>&1; then
  echo "error: rsvg-convert not found. Install with: brew install librsvg" >&2
  exit 1
fi

SPECIES=(
  cat
  orange-cat
  shiba
  owl
  capybara
)

FRAMES=(
  record-1-left
  record-2-front
  record-3-right
  record-4-front
  record-5-blink
  pause-1
  pause-2
  pause-3
)

for species in "${SPECIES[@]}"; do
  for frame in "${FRAMES[@]}"; do
    src="${SRC_DIR}/${species}/${frame}.svg"
    if [[ ! -f "$src" ]]; then
      echo "warn: missing source ${src}, skipping" >&2
      continue
    fi
    asset="${species}-${frame}"
    imageset_dir="${DST_DIR}/${asset}.imageset"
    mkdir -p "$imageset_dir"

    # Write Contents.json on first generation. Idempotent — overwrites with a
    # canonical layout so the file never drifts from what the asset catalog
    # expects (universal asset, three scales, no template rendering).
    cat > "${imageset_dir}/Contents.json" <<JSON
{
  "images" : [
    {
      "filename" : "${asset}.png",
      "idiom" : "universal",
      "scale" : "1x"
    },
    {
      "filename" : "${asset}@2x.png",
      "idiom" : "universal",
      "scale" : "2x"
    },
    {
      "filename" : "${asset}@3x.png",
      "idiom" : "universal",
      "scale" : "3x"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON

    for pair in "22:" "44:@2x" "66:@3x"; do
      size="${pair%:*}"
      suffix="${pair#*:}"
      out="${imageset_dir}/${asset}${suffix}.png"
      rsvg-convert -w "$size" -h "$size" "$src" -o "$out"
    done
    echo "  ${asset}"
  done
done

echo "done."
