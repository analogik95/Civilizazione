#!/usr/bin/env bash
# Downloads the CC0 Kenney asset packs this project draws its art from, then
# copies the pieces actually used into assets/art/.
#
#   ./tools/setup_assets.sh [cache_dir]      (default: .assetcache)
#
# The packs are cached but never committed — only the curated subset under
# assets/art/ is in git. Re-running is cheap: an already-downloaded pack is
# skipped.
#
# Every pack here is Creative Commons Zero, so the output is safe to ship.
# See assets/art/CREDITS.md.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="${1:-$ROOT/.assetcache}"
mkdir -p "$CACHE"

PACKS=(
  hexagon-kit        # hex terrain tiles, buildings, ships
  nature-kit         # trees, rocks, crops, cliffs
  castle-kit         # walls, towers, siege engines
  fantasy-town-kit   # fountains, carts, town props
  graveyard-kit      # obelisks, altars for Holy Sites
  blocky-characters  # unit meeples
  ui-pack            # 9-slice panels and buttons
  game-icons         # yield and action icons
  board-game-icons   # extra iconography
)

fail=0

for slug in "${PACKS[@]}"; do
  if [ -d "$CACHE/$slug" ]; then
    echo "have  $slug"
    continue
  fi

  # The download URL is generated per release and embedded in the asset page,
  # so scrape it rather than hard-coding a hash that will rot.
  url=$(curl -sL -m 40 "https://kenney.nl/assets/$slug" \
        | grep -oE "https://kenney\.nl/media/pages/assets/$slug/[a-f0-9]+-[0-9]+/[^']+\.zip" \
        | head -1)

  if [ -z "$url" ]; then
    echo "MISS  $slug (could not find download link)"
    fail=1
    continue
  fi

  echo "get   $slug"
  if ! curl -sL -m 300 -o "$CACHE/$slug.zip" "$url"; then
    echo "FAIL  $slug (download error)"
    fail=1
    continue
  fi

  size=$(stat -c%s "$CACHE/$slug.zip" 2>/dev/null || echo 0)
  if [ "$size" -lt 10000 ]; then
    echo "FAIL  $slug (suspiciously small: ${size}B)"
    rm -f "$CACHE/$slug.zip"
    fail=1
    continue
  fi

  mkdir -p "$CACHE/$slug"
  unzip -q -o "$CACHE/$slug.zip" -d "$CACHE/$slug"
  rm -f "$CACHE/$slug.zip"
done

if [ "$fail" -ne 0 ]; then
  echo
  echo "Some packs failed. Every pack is also downloadable by hand from"
  echo "https://kenney.nl/assets — unzip into $CACHE/<slug>/ and re-run."
fi

echo
python3 "$ROOT/tools/vendor_assets.py" "$CACHE"
