#!/usr/bin/env bash
# Builds a sample library into ./fixtures: series with several volumes, a standalone, a
# scanlation-named chapter, an unzipped folder of pages, and a PDF. Between them they cover
# every naming pattern NameParser knows and all three archive kinds.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="fixtures"
rm -rf "$OUT"
mkdir -p "$OUT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

render() { swift scripts/render-pages.swift "$@" >/dev/null; }

pack() { # pack <pages> <label> <destination.cbz> [--wide N]
  local pages="$1" label="$2" dest="$3"; shift 3
  local dir="$WORK/$(basename "$dest" .cbz)"
  mkdir -p "$dir"
  render "$dir" "$pages" "$label" "$@"
  mkdir -p "$(dirname "$dest")"
  (cd "$dir" && zip -q -r -X "$OLDPWD/$dest" .)
  echo "  $dest ($pages pages)"
}

echo "Building sample comics…"
# A run of volumes, one with a double-page spread in the middle.
pack 12 "Berserk v1" "$OUT/Berserk/Berserk v01 (2003) (Digital) (LuCaZ).cbz" --wide 5
pack 10 "Berserk v2" "$OUT/Berserk/Berserk v02 (2003) (Digital) (LuCaZ).cbz"
# Volume numbers only in the filename, series only in the folder.
pack 8 "Vinland Saga v1" "$OUT/Vinland Saga/v01.cbz"
pack 8 "Vinland Saga v2" "$OUT/Vinland Saga/v02.cbz"
# A standalone.
pack 6 "Akira" "$OUT/Akira.cbz"
# Scanlation naming: group tags, chapter, volume in parens.
pack 5 "Punpun c1" "$OUT/[Scans] Oyasumi Punpun - c001 (v01) [Pub].cbz"

# An unzipped volume: a folder of loose pages.
echo "  $OUT/One Punch Man/One Punch Man v03 (loose pages)"
mkdir -p "$OUT/One Punch Man/One Punch Man v03"
render "$OUT/One Punch Man/One Punch Man v03" 9 "One Punch Man v3"

# A PDF.
mkdir -p "$OUT/Lone Wolf and Cub"
swift scripts/render-pages.swift "$WORK/pdf" 7 "Lone Wolf v1" --pdf "$OUT/Lone Wolf and Cub/Lone Wolf and Cub v01.pdf" >/dev/null
echo "  $OUT/Lone Wolf and Cub/Lone Wolf and Cub v01.pdf (7 pages)"

echo
echo "Done. $(find "$OUT" -type f | wc -l | tr -d ' ') files, $(du -sh "$OUT" | cut -f1)."
echo "Install into the booted simulator with: make install-fixtures"
