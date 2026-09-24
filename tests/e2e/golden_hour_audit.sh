#!/usr/bin/env bash
# Golden-hour acceptance audit. It starts from empty directories and treats
# Hydronium as already hosted by publishing dist/orbit into a disposable file
# registry. Moonstone's public registry is declared explicitly in *both*
# projects so the LuaJIT runtime is never an ambient-machine dependency.
# `moonstone` is declared as an ordinary registry identity; the package
# namespace remains `moonstone/luajit`.
#
# Default mode reports unmet acceptance criteria but exits successfully so it
# can describe the current product honestly. Set HYDRONIUM_GOLDEN_STRICT=1 to
# make those unmet criteria fail once the generated path is complete.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
moon=${MOON_BIN:?Set MOON_BIN to the Moonstone executable under test}
release_root=${HYDRONIUM_RELEASE_ROOT:-"$root/dist/orbit"}
moonstone_registry=${MOONSTONE_REGISTRY_URL:-"https://registry.moonstone.sh/registry/v0"}
scratch=$(mktemp -d "${TMPDIR:-/tmp}/hydronium-golden-hour.XXXXXX")
registry="$scratch/hydronium-registry"
tool_project="$scratch/tool-project"
app="$scratch/golden-app"
server_pid=""
gaps=()

cleanup() {
  if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi
  if [[ ${HYDRONIUM_GOLDEN_KEEP:-0} == 1 ]]; then
    printf 'Golden-hour workspace retained at %s\n' "$scratch" >&2
  else
    rm -rf "$scratch"
  fi
}
trap cleanup EXIT
fail() { echo "golden-hour audit: $*" >&2; exit 1; }
gap() { gaps+=("$1"); printf 'GAP: %s\n' "$1"; }
[[ -x "$moon" ]] || fail "MOON_BIN is not executable: $moon"
[[ -d "$release_root" ]] || fail "missing release export: $release_root"
export PATH="$(dirname "$moon"):$PATH"

"$moon" registry create "$registry" hydronium-local
create_descriptor=$(find "$release_root" -type f -path '*/create/*/dist/registry/create/package.toml' -print -quit)
[[ -n "$create_descriptor" ]] || fail "missing exported hydronium/create descriptor"
create_version=$(awk -F '"' '/^version = / { print $2; exit }' "$create_descriptor")
[[ -n "$create_version" ]] || fail "could not read hydronium/create version from descriptor"
while IFS= read -r descriptor; do
  package_dir=$(dirname "$descriptor")
  blob=$(find "$package_dir" -maxdepth 1 -type f -name '*.tar.gz' -print -quit)
  [[ -n "$blob" ]] || fail "no artifact beside $descriptor"
  "$moon" registry push "$registry" --descriptor "$descriptor" --blob "$blob"
done < <(find "$release_root" -type f \( -path '*/dist/registry/package.toml' -o -path '*/dist/registry/*/package.toml' \) -print | sort)

export XDG_DATA_HOME="$scratch/data"
export XDG_CONFIG_HOME="$scratch/config"
mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME"

"$moon" init "$tool_project" --name golden-hour-tool --kind script --interpreter luajit@2.1 --no-sync --no-git
(
  cd "$tool_project"
  "$moon" registry add moonstone "$moonstone_registry"
  "$moon" registry add hydronium-local "file://$registry"
  grep -Fq 'name = "moonstone"' moonstone.toml || fail "tool project does not explicitly declare Moonstone registry"
  grep -Fq "url = \"$moonstone_registry\"" moonstone.toml || fail "tool project has wrong Moonstone registry URL"
  "$moon" add "hydronium-local:hydronium/create@$create_version"
  "$moon" exec -- hydronium-create "$app" --template ssr --name golden-hour-app
)

(
  cd "$app"
  "$moon" registry add moonstone "$moonstone_registry"
  "$moon" registry add hydronium-local "file://$registry"
  grep -Fq 'name = "moonstone"' moonstone.toml || fail "application does not explicitly declare Moonstone registry"
  grep -Fq "url = \"$moonstone_registry\"" moonstone.toml || fail "application has wrong Moonstone registry URL"
  "$moon" sync
  "$moon" sync --locked
  grep -Fq 'name=moonstone/luajit' moonstone.lock || fail "lockfile did not resolve LuaJIT from Moonstone"
  if grep -rnF "$root" .moonstone moonstone.lock .luarc.json; then fail "generated project leaked a source checkout path"; fi
  grep -Fq 'hydronium_luax/luals/init.lua' .luarc.json || fail "generated LuaLS config lacks LUAX plugin"
  grep -Fq 'hydronium-luax/types' .luarc.json || fail "generated LuaLS config lacks LUAX types"
  grep -Fq 'hydronium-dom/types' .luarc.json || fail "generated LuaLS config lacks DOM types"
  "$moon" run build
  [[ -x dist/server ]] || fail "build did not produce dist/server"
  if ! rg -q '^test\s*=' moonstone.toml; then gap "generated SSR app has no test command"; fi
  if [[ ! -f partiture.lua ]]; then gap "generated SSR app has no release partiture/artifact command"; fi
)

(cd "$app" && exec ./dist/server) >"$scratch/server.log" 2>&1 &
server_pid=$!
for _ in $(seq 1 100); do
  if curl --fail --silent http://127.0.0.1:8080/ >"$scratch/index.html"; then break; fi
  sleep 0.1
done
[[ -s "$scratch/index.html" ]] || { cat "$scratch/server.log" >&2 || true; fail "built app never served a document"; }
grep -Fq 'golden-hour-app' "$scratch/index.html" || fail "served document lacks generated application markup"

# `dev` is generated, but a source-edit/HMR browser proof is intentionally not
# claimed by this audit until it can be driven from a fresh artifact consumer.
if ! rg -q '^dev\s*=' "$app/moonstone.toml"; then gap "generated SSR app has no dev/HMR command"; fi
gap "fresh artifact consumer does not yet drive a component edit through HMR"

printf '\nGolden-hour implemented steps: create -> editor config -> run -> locked replay -> build -> served document\n'
if ((${#gaps[@]})); then
  printf 'Golden-hour gaps (%d):\n' "${#gaps[@]}"
  for item in "${gaps[@]}"; do printf '  - %s\n' "$item"; done
  if [[ ${HYDRONIUM_GOLDEN_STRICT:-0} == 1 ]]; then exit 1; fi
else
  printf 'Golden-hour acceptance: complete\n'
fi
