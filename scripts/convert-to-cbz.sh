#!/usr/bin/env bash
# Converts comics Mango can't open — RAR (.cbr .rar), 7z (.cb7 .7z), tar (.cbt .tar) — into
# .cbz, next to the originals. Mango leaves RAR out on purpose (its only decoder is non-free and
# can't ship in a GPL-3 app) and doesn't read 7z or tar; a .cbz is a plain zip every reader opens.
#
#   scripts/convert-to-cbz.sh [--delete] <folder>...
#
# Needs `zip` and an extractor: `7zz` (brew install sevenzip) or `unar` (brew install unar)
# handle everything; `unrar` handles RAR (and is preferred for it — unar chokes on some RAR4
# archives that unrar reads fine); `7z` (p7zip) handles 7z but has no RAR codec.
# Point it at the share mounted in Finder (Go → Connect to Server) to convert a NAS in place.
# Originals are kept unless --delete, and an existing .cbz is never overwritten. Pages are
# stored, not compressed: JPEGs don't shrink, and a stored zip is the fastest thing to read
# over a network.
set -euo pipefail

log() { echo "[$(date +%T)] $*" >&2; }

delete=0
if [[ "${1:-}" == "--delete" ]]; then delete=1; shift; fi
[[ $# -gt 0 ]] || { echo "usage: $0 [--delete] <folder>..." >&2; exit 64; }

has() { command -v "$1" >/dev/null; }

# Extracts $1 into $2 with the first tool that can read that format.
extract() {
  case "${1,,}" in
    *.cbr|*.rar)
      # RARLAB's own unrar first: it's the reference decoder, and unar fails partway through
      # some intact RAR4 archives ("Attempted to read more data than was available").
      if has unrar; then unrar x -o+ -inul "$1" "$2/"
      elif has 7zz; then 7zz x -y -bso0 -bsp0 -o"$2" "$1"
      elif has unar; then unar -q -f -o "$2" "$1"
      else log "no RAR extractor: brew install sevenzip (or unar)"; return 1; fi ;;
    *.cbt|*.tar)
      tar -xf "$1" -C "$2" ;;
    *)
      if has 7zz; then 7zz x -y -bso0 -bsp0 -o"$2" "$1"
      elif has 7z; then 7z x -y -bso0 -bsp0 -o"$2" "$1"
      elif has unar; then unar -q -f -o "$2" "$1"
      else log "no 7z extractor: brew install sevenzip"; return 1; fi ;;
  esac
}
has zip || { echo "need zip" >&2; exit 69; }

converted=0 skipped=0 failed=0
started=$SECONDS
while IFS= read -r -d '' archive; do
  target="${archive%.*}.cbz"
  if [[ -e "$target" ]]; then
    log "skip (already converted): $(basename "$target")"
    skipped=$((skipped + 1)); continue
  fi
  work=$(mktemp -d)
  t0=$SECONDS
  if extract "$archive" "$work" && [[ -n "$(find "$work" -type f | head -1)" ]]; then
    # Build beside the target and move into place, so a half-written .cbz never exists.
    (cd "$work" && zip -0 -r -q -X "$work/out.cbz" . -x 'out.cbz' -x '*.DS_Store' -x '__MACOSX/*')
    mv "$work/out.cbz" "$target"
    log "converted $(basename "$archive") → $(basename "$target") ($(du -h "$target" | cut -f1)) in $((SECONDS - t0))s"
    converted=$((converted + 1))
    if [[ $delete -eq 1 ]]; then rm -f "$archive"; fi
  else
    log "FAILED to extract $(basename "$archive") — left as is"
    failed=$((failed + 1))
  fi
  rm -rf "$work"
done < <(find "$@" -type f \( -iname '*.cbr' -o -iname '*.rar' -o -iname '*.cb7' -o -iname '*.7z' -o -iname '*.cbt' -o -iname '*.tar' \) -print0)

log "done: $converted converted, $skipped already there, $failed failed in $((SECONDS - started))s"
[[ $failed -eq 0 ]]
