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
# shellcheck source=lib/local_registry.sh
source "$root/tests/e2e/lib/local_registry.sh"

"$moon" registry create "$registry" hydronium-data-primitives
while IFS= read -r descriptor; do
  package_dir=$(dirname "$descriptor")
  blob=$(find "$package_dir" -maxdepth 1 -type f -name '*.tar.gz' -print -quit)
  [[ -n "$blob" ]] || fail "no artifact beside $descriptor"
  # Pin the packages' own hydronium/* dependencies to this registry too, so
  # the gate consumes the export rather than the last published release.
  rewritten="$scratch/$(basename "$package_dir").package.toml"
  rewrite_hydronium_deps "$descriptor" "$rewritten" hydronium-data-primitives
  "$moon" registry push "$registry" --descriptor "$rewritten" --blob "$blob"
done < <(find "$release_root" -type f \( -path '*/dist/registry/package.toml' -o -path '*/dist/registry/*/package.toml' \) -print | sort)

export XDG_DATA_HOME="$scratch/data"
export XDG_CONFIG_HOME="$scratch/config"
mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME"
"$moon" init "$app" --name data-primitives-consumer --kind script --interpreter luajit@2.1 --no-sync --no-git
cp "$root/tests/fixtures/consumer_data_primitives.lua" "$app/main.lua"
(
  cd "$app"
  "$moon" registry add hydronium-data-primitives "file://$registry"
  "$moon" add hydronium-data-primitives:hydronium/query
  "$moon" add hydronium-data-primitives:hydronium/virtual
  "$moon" add hydronium-data-primitives:hydronium/table
  "$moon" sync
  "$moon" sync --locked
  if grep -rnF "$root" .moonstone moonstone.lock; then fail "consumer environment references the source checkout"; fi
  if grep -nE 'constraint = "path:|registry = "path"' moonstone.toml moonstone.lock; then fail "consumer retained a path dependency"; fi
  "$moon" exec -- luajit main.lua
)
echo "data primitives consumer gate passed: exported registry -> locked sync -> executable query/table/virtual model"
