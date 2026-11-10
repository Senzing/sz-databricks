#!/usr/bin/env bash
# check_release_assets.sh <dir> <release>: fail unless <dir> holds exactly the files of release <release>
# (the tag, <senzing_version>-<build>), as release-assets.yaml names them. The private build runs it
# before it publishes; the public signing workflow runs the same script (copied there by
# scripts/sync_public.sh) before it signs SHA256SUMS, the one signature that covers every file. Checks:
#   - the exact file set: one native archive per arch, the shared archive, the bundle tarball and
#     SHA256SUMS; none empty or a link
#   - SHA256SUMS lists exactly the others and verifies
#   - the bundle tarball holds exactly bundle_members
#   - the bundle's engine JAR (bundle_app_jar) holds exactly jar_members under jar_dirs, and its
#     release/payload-digests.txt lists the payload archives and the shared archive's payload manifest,
#     each matching
#   - with RELEASE_REPO set, the JAR's release/release-repo.txt names that repository
# RELEASE_ASSETS=<yaml> reads another manifest (default: release-assets.yaml beside this script's parent,
# or public/release-assets.yaml in the private repository).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dir="${1:?usage: check_release_assets.sh <dir> <release>}"; release="${2:?usage: check_release_assets.sh <dir> <release>}"
manifest="${RELEASE_ASSETS:-}"
if [ -z "$manifest" ]; then
  for m in "$here/../release-assets.yaml" "$here/../public/release-assets.yaml"; do [ -f "$m" ] && { manifest="$m"; break; }; done
fi
[ -f "$manifest" ] || { echo "check_release_assets.sh: no release-assets.yaml" >&2; exit 2; }
[ -d "$dir" ] || { echo "check_release_assets.sh: $dir is not a directory" >&2; exit 1; }
[[ "$release" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[1-9][0-9]*$ ]] || { echo "check_release_assets.sh: '$release' is not <senzing_version>-<build>" >&2; exit 1; }
ra() { local v; v="$("$here/build_yaml.sh" "$1" "$manifest")"; v="${v//\{release\}/$release}"; printf '%s\n' "${v//\{arch\}/${2:-}}"; }
if command -v sha256sum >/dev/null; then sum=(sha256sum); else sum=(shasum -a 256); fi
digest() { "${sum[@]}" | awk '{ print $1 }'; }
lines() { tr ' ' '\n' | grep -v '^$' | LC_ALL=C sort; }
fail=0
err() { echo "check_release_assets.sh: $*" >&2; fail=1; }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

shared="$(ra release_shared_archive)"; bundle="$(ra release_bundle_archive)"; sums="$(ra release_sums)"
archives=("$shared"); for a in $(ra release_archs); do archives+=("$(ra release_native_archive "$a")"); done
deliverables=("${archives[@]}" "$bundle")

# The exact set.
actual="$(find "$dir" -mindepth 1 -maxdepth 1 -exec basename {} \; | LC_ALL=C sort)"
expected="$(printf '%s\n' "${deliverables[@]}" "$sums" | LC_ALL=C sort)"
[ "$actual" = "$expected" ] || err "$dir holds
$actual
but must hold exactly
$expected"
for f in "${deliverables[@]}" "$sums"; do
  if [ ! -s "$dir/$f" ] || [ -L "$dir/$f" ]; then err "$f is missing, empty or a link"; fi
done

# SHA256SUMS: exactly the deliverables, verifying.
if [ -s "$dir/$sums" ]; then
  listed="$(awk '{ sub(/^\*/, "", $2); print $2 }' "$dir/$sums" | LC_ALL=C sort)"
  [ "$listed" = "$(printf '%s\n' "${deliverables[@]}" | LC_ALL=C sort)" ] || err "$sums lists
$listed
not exactly the release files"
  (cd "$dir" && "${sum[@]}" -c "$sums" >/dev/null 2>&1) || err "$sums does not verify"
fi

# The bundle tarball: exactly its members; its engine JAR is extracted for the checks below.
jar="$(ra bundle_app_jar)"
if [ -s "$dir/$bundle" ]; then
  if members="$(tar -tzf "$dir/$bundle" 2>/dev/null)"; then
    got="$(grep -v '/$' <<< "$members" | LC_ALL=C sort)"
    want="$(ra bundle_members | lines)"
    [ "$got" = "$want" ] || err "$bundle holds
$got
but must hold exactly
$want"
    if grep -xF "$jar" <<< "$got" >/dev/null; then
      tar -xzOf "$dir/$bundle" "$jar" > "$work/engine.jar" || err "$bundle: $jar cannot be extracted"
    else
      err "$bundle holds no $jar"
    fi
  else
    err "$bundle is not a readable tar.gz"
  fi
fi

# The engine JAR: exactly jar_members under jar_dirs; the payload digests bind the archives.
if [ -s "$work/engine.jar" ]; then
  if entries="$(unzip -Z1 "$work/engine.jar" 2>/dev/null)"; then
    pat="^($(ra jar_dirs | tr ' ' '|'))/[^/]"
    got="$(grep -E "$pat" <<< "$entries" | grep -v '/$' | LC_ALL=C sort || true)"
    want="$(ra jar_members | lines)"
    [ "$got" = "$want" ] || err "$jar holds
$got
under $(ra jar_dirs), but must hold exactly
$want"
    unzip -p "$work/engine.jar" release/payload-digests.txt > "$work/digests" 2>/dev/null || true
    pm="$(ra payload_manifest)"
    listed="$(awk '{ sub(/^\*/, "", $2); print $2 }' "$work/digests" | LC_ALL=C sort)"
    [ "$listed" = "$(printf '%s\n' "${archives[@]}" "$pm" | LC_ALL=C sort)" ] \
      || err "$jar release/payload-digests.txt lists
$listed
not the payload archives and $pm"
    for a in "${archives[@]}"; do
      want="$(awk -v n="$a" '$2 == n || $2 == "*" n { print $1; exit }' "$work/digests")"
      if [ -s "$dir/$a" ] && [ -n "$want" ] && [ "$(digest < "$dir/$a")" != "$want" ]; then err "$a does not match its digest in $jar"; fi
    done
    want="$(awk -v n="$pm" '$2 == n || $2 == "*" n { print $1; exit }' "$work/digests")"
    if [ -s "$dir/$shared" ] && [ -n "$want" ]; then
      [ "$(tar -xzOf "$dir/$shared" "$pm" 2>/dev/null | digest)" = "$want" ] || err "$shared: $pm does not match its digest in $jar"
    fi
    if [ -n "${RELEASE_REPO:-}" ]; then
      [ "$(unzip -p "$work/engine.jar" release/release-repo.txt 2>/dev/null)" = "$RELEASE_REPO" ] \
        || err "$jar release/release-repo.txt does not name $RELEASE_REPO"
    fi
  else
    err "$jar is not a readable JAR"
  fi
fi

[ "$fail" = 0 ] || exit 1
echo "check_release_assets.sh: release $release: ${#deliverables[@]} files and $sums ok"
