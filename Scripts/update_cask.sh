#!/usr/bin/env bash
set -euo pipefail

# Bump the Homebrew tap cask to a released NightOwl version.
#
# Usage:
#   Scripts/update_cask.sh <version> [path-to-tap-cask]
#
# Defaults to a sibling checkout at ../homebrew-tap/Casks/nightowl.rb and reads
# the matching dist/NightOwl-<version>.zip to recompute the sha256.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:?usage: update_cask.sh <version> [path-to-tap-cask]}"
CASK="${2:-$ROOT/../homebrew-tap/Casks/nightowl.rb}"
ZIP="$ROOT/dist/NightOwl-$VERSION.zip"

[ -f "$ZIP" ] || { echo "zip not found: $ZIP (run ./build.sh and zip the app first)"; exit 1; }
[ -f "$CASK" ] || { echo "cask not found: $CASK"; exit 1; }

SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"

/usr/bin/sed -i '' -E "s/^(  version )\"[^\"]+\"/\1\"$VERSION\"/" "$CASK"
/usr/bin/sed -i '' -E "s/^(  sha256 )\"[^\"]+\"/\1\"$SHA\"/" "$CASK"

echo "Updated $CASK"
echo "  version $VERSION"
echo "  sha256  $SHA"
echo ""
echo "Next: commit & push the tap, then verify with 'brew audit --cask nightowl'."
