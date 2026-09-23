#!/usr/bin/env bash
# Consumer gate: package Hydronium exactly as CI does, then consume it from a
# disposable file registry.  This deliberately never puts this checkout on
# LUA_PATH: a source-tree import would make the test pass while a published
# package was incomplete.
#
# Prerequisites (provided by CI):
#   MOON_BIN             an already-built Moonstone CLI
#   HYDRONIUM_BROWSER_GATE a Node command which drives the started server
#
# Run from the Hydronium repository root after `ballad play partiture.lua`:
#   MOON_BIN=/path/to/moon HYDRONIUM_BROWSER_GATE='node --test ...' \
#     bash tests/e2e/consumer_scaffold.sh
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
moon=${MOON_BIN:?Set MOON_BIN to the Moonstone executable under test}
browser_gate=${HYDRONIUM_BROWSER_GATE:?Set HYDRONIUM_BROWSER_GATE to the Playwright assertion command}
release_root=${HYDRONIUM_RELEASE_ROOT:-"$root/dist/orbit"}
scratch=$(mktemp -d "${TMPDIR:-/tmp}/hydronium-consumer.XXXXXX")
registry="$scratch/registry"
tool_project="$scratch/tool-project"
app="$scratch/islands-app"
server_pid=""

cleanup() {
  if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$scratch"
}
trap cleanup EXIT

fail() { echo "consumer gate: $*" >&2; exit 1; }
[[ -x "$moon" ]] || fail "MOON_BIN is not executable: $moon"
[[ -d "$release_root" ]] || fail "package release is missing: $release_root (run ballad export first)"

# Generated project scripts invoke `moon` themselves.  Keep those nested
# invocations on the exact CLI under test instead of silently picking up an
# older user-global installation from PATH.
export PATH="$(dirname "$moon"):$PATH"

# A registry push copies the descriptor and blob into a registry-shaped tree;
# it is intentionally not a path dependency or a link-store registration.
"$moon" registry create "$registry" hydronium-consumer
descriptor_count=0
create_descriptor_count=0
while IFS= read -r descriptor; do
  descriptor_count=$((descriptor_count + 1))
  if rg -q '^name = "hydronium/create"$' "$descriptor"; then
    create_descriptor_count=$((create_descriptor_count + 1))
  fi
  package_dir=$(dirname "$descriptor")
  blob=$(find "$package_dir" -maxdepth 1 -type f -name '*.tar.gz' -print -quit)
  [[ -n "$blob" ]] || fail "no artifact beside exported descriptor: $descriptor"
  "$moon" registry push "$registry" --descriptor "$descriptor" --blob "$blob"
done < <(find "$release_root" -type f \( -path '*/dist/registry/package.toml' -o -path '*/dist/registry/*/package.toml' \) -print | sort)

(( descriptor_count > 0 )) || fail "export contained no package descriptors: $release_root"
(( create_descriptor_count == 1 )) || fail "export must contain exactly one hydronium/create descriptor (found $create_descriptor_count)"
[[ -f "$registry/index.toml" ]] || fail "file registry index was not created"

# Use fresh Moonstone state.  The default Moonstone registry still supplies
# Moonstone/Meteorite itself; every Hydronium package comes from the local
# exported registry above.
export XDG_DATA_HOME="$scratch/data"
export XDG_CONFIG_HOME="$scratch/config"
mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$tool_project"

"$moon" init "$tool_project" --name hydronium-consumer-tool --kind script --interpreter luajit@2.1 --no-sync --no-git
(
  cd "$tool_project"
  "$moon" registry add hydronium-consumer "file://$registry"
  "$moon" add hydronium/create
  "$moon" exec -- hydronium-create "$app" --template islands --name consumer-islands
)

(
  cd "$app"
  "$moon" registry add hydronium-consumer "file://$registry"
  "$moon" sync
  "$moon" sync --locked

  # The application must be materialized from package artifacts, not be able
  # to fall through to this repository via an accidentally inherited path.
  if rg -n --fixed-strings "$root" .moonstone moonstone.lock; then
    fail "consumer environment references this Hydronium checkout"
  fi
  if rg -n 'constraint = "path:|registry = "path"' moonstone.toml moonstone.lock; then
    fail "consumer manifest or lock retained a path dependency"
  fi

  "$moon" run build
  [[ -x dist/server ]] || fail "template build did not produce dist/server"
)

(cd "$app" && exec ./dist/server) >"$scratch/server.log" 2>&1 &
server_pid=$!

# Do not accept a listening socket as proof: wait for a real, successful
# document response.  Browser assertions below then prove the document and
# its client island actually execute without invisible failures.
for _ in $(seq 1 100); do
  if curl --fail --silent --show-error http://127.0.0.1:8080/ >"$scratch/index.html"; then break; fi
  sleep 0.1
done
[[ -s "$scratch/index.html" ]] || { cat "$scratch/server.log" >&2 || true; fail "built server never returned /"; }
rg -q 'consumer-islands' "$scratch/index.html" || fail "SSR response lacks scaffolded application markup"

HYDRONIUM_CONSUMER_URL=http://127.0.0.1:8080 HYDRONIUM_CONSUMER_LOG="$scratch/server.log" \
  bash -lc "$browser_gate"

echo "consumer gate passed: exported registry -> scaffold -> locked sync -> build -> browser"
