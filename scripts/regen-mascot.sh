#!/usr/bin/env bash
# Regenerate mascot PNGs from SVG sources using librsvg's rsvg-convert.
#
# Why rsvg-convert and not sips/qlmanage: qlmanage flattens the alpha channel
# against an opaque white background, which made the 22pt mascot render as a
# solid white square in the menu bar. rsvg-convert preserves transparency.
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

ASSETS=(
  record-1-left
  record-2-front
  record-3-right
  record-4-front
  record-5-blink
  pause-1
  pause-2
  pause-3
)

for asset in "${ASSETS[@]}"; do
  src="${SRC_DIR}/${asset}.svg"
  if [[ ! -f "$src" ]]; then
    echo "warn: missing source ${src}, skipping" >&2
    continue
  fi
  for pair in "22:" "44:@2x" "66:@3x"; do
    size="${pair%:*}"
    suffix="${pair#*:}"
    out="${DST_DIR}/${asset}.imageset/${asset}${suffix}.png"
    rsvg-convert -w "$size" -h "$size" "$src" -o "$out"
    echo "  ${out}"
  done
done

echo "done."
