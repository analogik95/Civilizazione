#!/usr/bin/env bash
# Fetches the pinned Godot and Blender builds this project is developed against.
# Both are portable archives — nothing is installed system-wide.
#
#   ./tools/setup_toolchain.sh [dest_dir]      (default: .toolchain)
#
# After running, use:
#   $DEST/godot --headless --path . ...
#   $DEST/blender/blender --background --python tools/blender/build_assets.py

set -euo pipefail

GODOT_VERSION="4.7-stable"
BLENDER_VERSION="4.5.9"
DEST="${1:-$(cd "$(dirname "$0")/.." && pwd)/.toolchain}"

mkdir -p "$DEST"
cd "$DEST"

if [ ! -x "$DEST/godot" ]; then
  echo "==> Fetching Godot ${GODOT_VERSION}"
  curl -fsSL -o godot.zip \
    "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}/Godot_v${GODOT_VERSION}_linux.x86_64.zip"
  unzip -oq godot.zip
  mv "Godot_v${GODOT_VERSION}_linux.x86_64" godot
  chmod +x godot
  rm -f godot.zip
fi
echo "Godot: $("$DEST/godot" --headless --version)"

if [ ! -x "$DEST/blender/blender" ]; then
  echo "==> Fetching Blender ${BLENDER_VERSION} LTS"
  BLENDER_SERIES="${BLENDER_VERSION%.*}"
  curl -fsSL -o blender.tar.xz \
    "https://download.blender.org/release/Blender${BLENDER_SERIES}/blender-${BLENDER_VERSION}-linux-x64.tar.xz"
  tar -xf blender.tar.xz
  mv "blender-${BLENDER_VERSION}-linux-x64" blender
  rm -f blender.tar.xz
fi
echo "Blender: $("$DEST/blender/blender" --background --version 2>/dev/null | head -1)"

echo
echo "Toolchain ready in $DEST"
