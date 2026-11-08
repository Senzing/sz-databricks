#!/usr/bin/env bash
# scan_refs.sh <denylist.yaml> [--sections <a,b>] <path>...: fail when a file under a <path> (a file, or a
# directory, recursively; symlinks are not followed) carries a pattern of the denylist.
# Sections (each entry one quoted POSIX ERE; default: every section the file has):
#   names, attribution   every byte of every file (grep -a, binaries included), case-insensitive
#   ids                  text files only (grep -I), case-sensitive
#   words                text files only (grep -I), case-insensitive
# Binary files are never held to ids or words: bytes of machine code or a digest match D[0-9] by chance.
# Fails closed: a missing path, no file to scan, a symlink, an empty pattern list or a grep error (an
# invalid pattern) is a failure.
#   scan_refs.sh --patterns <denylist.yaml> <section>   print a section's entries, one per line
set -euo pipefail

# entries <file> <section>: the section's quoted values, unquoted ('' is a quote).
entries() {
  awk -v s="$2" '/^[a-z_]+:[[:space:]]*$/ { on = ($1 == s ":"); next } /^[^ #]/ { on = 0 } on' "$1" |
    sed -n -E "s/^  - '((''|[^'])*)'[[:space:]]*(#.*)?$/\1/p" | sed "s/''/'/g"
}

if [ "${1:-}" = --patterns ]; then entries "${2:?denylist}" "${3:?section}"; exit 0; fi
list="${1:?usage: scan_refs.sh <denylist.yaml> [--sections <a,b>] <path>...}"; shift
[ -f "$list" ] || { echo "scan_refs.sh: $list is not a file" >&2; exit 2; }
sections="names attribution ids words"
if [ "${1:-}" = --sections ]; then sections="${2:?--sections needs a list}"; sections="${sections//,/ }"; shift 2; fi
[ $# -gt 0 ] || { echo "usage: scan_refs.sh <denylist.yaml> [--sections <a,b>] <path>..." >&2; exit 2; }
for p in "$@"; do [ -e "$p" ] || { echo "scan_refs.sh: $p does not exist" >&2; exit 2; }; done
# A scan of nothing is not clean, and a symlink would be skipped here but followed by whatever reads it.
[ -n "$(find "$@" -type f -print -quit)" ] || { echo "scan_refs.sh: no files under $*" >&2; exit 2; }
links="$(find "$@" -type l)"
[ -z "$links" ] || { echo "scan_refs.sh: symlinks are not scanned, refused: $links" >&2; exit 2; }

status=0 total=0
hitlist="$(mktemp)"; trap 'rm -f "$hitlist"' EXIT
for s in $sections; do
  case "$s" in
    names | attribution) flags=(-a -i) ;;
    ids) flags=(-I) ;;
    words) flags=(-I -i) ;;
    *) echo "scan_refs.sh: unknown section $s" >&2; exit 2 ;;
  esac
  pats=(); while IFS= read -r p; do pats+=(-e "$p"); done < <(entries "$list" "$s")
  [ "${#pats[@]}" -gt 0 ] || continue
  total=$((total + ${#pats[@]} / 2)); rc=0
  # One pass over the tree for the whole section; only the files it hits are searched per pattern.
  LC_ALL=C grep -r -l -E "${flags[@]}" "${pats[@]}" -- "$@" > "$hitlist" || rc=$?
  hits=(); while IFS= read -r f; do hits+=("$f"); done < "$hitlist"
  case "$rc" in
    0) ;;
    1) continue ;;
    *) echo "scan_refs.sh: grep failed on the $s patterns: nothing was scanned" >&2; exit 2 ;;
  esac
  while IFS= read -r p; do
    rc=0
    files="$(LC_ALL=C grep -l -E "${flags[@]}" -e "$p" -- "${hits[@]}")" || rc=$?
    case "$rc" in
      0) status=1
         while IFS= read -r f; do
           printf 'scan_refs.sh: %s: %s /%s/: %s\n' "$f" "$s" "$p" \
             "$(LC_ALL=C grep -o -E "${flags[@]}" -e "$p" -- "$f" | head -3 | tr -c '[:print:]\n' '?' | tr '\n' ' ')" >&2
         done <<< "$files" ;;
      1) ;;
      *) echo "scan_refs.sh: grep failed on /$p/ ($s): nothing was scanned" >&2; exit 2 ;;
    esac
  done < <(entries "$list" "$s")
done
[ "$total" -gt 0 ] || { echo "scan_refs.sh: $list has no patterns in: $sections" >&2; exit 2; }
exit "$status"
