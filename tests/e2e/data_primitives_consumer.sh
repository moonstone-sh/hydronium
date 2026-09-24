#!/usr/bin/env bash
# Proves query, virtual and table can be installed from exported artifacts.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
moon=${MOON_BIN:?Set MOON_BIN to the Moonstone executable under test}
release_root=${HYDRONIUM_RELEASE_ROOT:-"$root/dist/orbit"}
scratch=$(mktemp -d "${TMPDIR:-/tmp}/hydronium-data-primitives.XXXXXX")
registry="$scratch/registry"
app="$scratch/app"
cleanup() { rm -rf "$scratch"; }
trap cleanup EXIT
fail() { echo "data primitives consumer gate: $*" >&2; exit 1; }
[[ -x "$moon" ]] || fail "MOON_BIN is not executable: $moon"
[[ -d "$release_root" ]] || fail "package release is missing: $release_root"
export PATH="$(dirname "$moon"):$PATH"

"$moon" registry create "$registry" hydronium-data-primitives
while IFS= read -r descriptor; do
  package_dir=$(dirname "$descriptor")
  blob=$(find "$package_dir" -maxdepth 1 -type f -name '*.tar.gz' -print -quit)
  [[ -n "$blob" ]] || fail "no artifact beside $descriptor"
  "$moon" registry push "$registry" --descriptor "$descriptor" --blob "$blob"
done < <(find "$release_root" -type f \( -path '*/dist/registry/package.toml' -o -path '*/dist/registry/*/package.toml' \) -print | sort)

export XDG_DATA_HOME="$scratch/data"
export XDG_CONFIG_HOME="$scratch/config"
mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME"
"$moon" init "$app" --name data-primitives-consumer --kind script --interpreter luajit@2.1 --no-sync --no-git
cp "$root/tests/fixtures/consumer_data_primitives.lua" "$app/main.lua"
(
  cd "$app"
  "$moon" registry add hydronium-data-primitives "file://$registry"
  "$moon" add hydronium-data-primitives:hydronium/query@0.1.0
  "$moon" add hydronium-data-primitives:hydronium/virtual@0.1.0
  "$moon" add hydronium-data-primitives:hydronium/table@0.1.0
  "$moon" sync
  "$moon" sync --locked
  if grep -rnF "$root" .moonstone moonstone.lock; then fail "consumer environment references the source checkout"; fi
  if grep -nE 'constraint = "path:|registry = "path"' moonstone.toml moonstone.lock; then fail "consumer retained a path dependency"; fi
  "$moon" exec -- luajit main.lua
)
echo "data primitives consumer gate passed: exported registry -> locked sync -> executable query/table/virtual model"
