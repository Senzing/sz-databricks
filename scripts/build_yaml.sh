#!/usr/bin/env bash
# Print one top-level scalar from build.yaml (or the flat YAML file given as the second
# argument): scripts/build_yaml.sh <key> [file]. No yq: the files are flat on purpose.
# Fails when the key is absent.
set -euo pipefail
key="${1:?usage: build_yaml.sh <key> [file]}"
file="${2:-$(dirname "$0")/../build.yaml}"
value="$(sed -n -E "s/^${key}:[[:space:]]*//p" "$file" | head -n 1 | sed -E 's/^"(.*)"$/\1/; s/[[:space:]]*#.*$//')"
[ -n "$value" ] || { echo "build_yaml.sh: no key '$key' in $file" >&2; exit 1; }
printf '%s\n' "$value"
