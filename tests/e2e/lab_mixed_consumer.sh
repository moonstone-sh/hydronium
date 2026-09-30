#!/usr/bin/env bash
# Proves query, virtual and table can be installed from exported artifacts.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
moon=${MOON_BIN:?Set MOON_BIN to the Moonstone executable under test}
release_root=${HYDRONIUM_RELEASE_ROOT:-"$root/dist/orbit"}
scratch=$(mktemp -d "${TMPDIR:-/tmp}/hydronium-mixed-lab.XXXXXX")
registry="$scratch/registry"
app="$scratch/app"
server_pid=""
# Meteorite dev daemonizes its supervisor and server, so killing the subshell
# alone leaked them (still listening on the Lab port for the next run). Stop
# everything started from this run's scratch directory. Match its unique
# random name, not the full path: macOS's TMPDIR ends in "/", so "$scratch"
# holds a "//" that the processes' own (normalized) paths do not.
cleanup() {
  local tag; tag=$(basename "$scratch")
  if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; fi
  pkill -f "$tag" 2>/dev/null || true; sleep 1; pkill -9 -f "$tag" 2>/dev/null || true
  rm -rf "$scratch"
}
trap cleanup EXIT
fail() { echo "data primitives consumer gate: $*" >&2; exit 1; }
[[ -x "$moon" ]] || fail "MOON_BIN is not executable: $moon"
[[ -d "$release_root" ]] || fail "package release is missing: $release_root"
export PATH="$(dirname "$moon"):$PATH"
# shellcheck source=lib/local_registry.sh
source "$root/tests/e2e/lib/local_registry.sh"

"$moon" registry create "$registry" hydronium-mixed-lab
while IFS= read -r descriptor; do
  package_dir=$(dirname "$descriptor")
  blob=$(find "$package_dir" -maxdepth 1 -type f -name '*.tar.gz' -print -quit)
  [[ -n "$blob" ]] || fail "no artifact beside $descriptor"
  # Pin the packages' own hydronium/* dependencies to this registry too, so
  # the gate consumes the export rather than the last published release.
  rewritten="$scratch/$(basename "$package_dir").package.toml"
  rewrite_hydronium_deps "$descriptor" "$rewritten" hydronium-mixed-lab
  "$moon" registry push "$registry" --descriptor "$rewritten" --blob "$blob"
done < <(find "$release_root" -type f \( -path '*/dist/registry/package.toml' -o -path '*/dist/registry/*/package.toml' \) -print | sort)

export XDG_DATA_HOME="$scratch/data"
export XDG_CONFIG_HOME="$scratch/config"
mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME"
"$moon" init "$app" --name mixed-lab-consumer --kind script --interpreter luajit@2.1 --no-sync --no-git
# `moon init` already made src/: copy the fixture's contents into it, not the
# directory itself (that nests it at src/lab_mixed and breaks every require).
cp -R "$root/tests/fixtures/lab_mixed/." "$app/src/"
cat > "$app/hydronium.lab.lua" <<'CONFIG'
return { renderer = "mixed", roots = { "src" }, base_path = "/lab" }
CONFIG
(
  cd "$app"
  "$moon" registry add hydronium-mixed-lab "file://$registry"
  "$moon" add --tool --no-sync hydronium-mixed-lab:hydronium/lab-cli moonstone/meteorite
  "$moon" add --dev --no-sync hydronium-mixed-lab:hydronium/lab hydronium-mixed-lab:hydronium/ink-lab hydronium-mixed-lab:hydronium/meteorite
  "$moon" sync
  "$moon" sync --locked
  # grep, not rg: CI runners do not ship ripgrep (a missing rg silently skipped this check).
  if grep -rnF "$root" .moonstone moonstone.lock; then fail "consumer references source checkout"; fi
  "$moon" exec --dev -- hydronium-lab dev --port 6196 > "$scratch/server.log" 2>&1 &
  echo $! > "$scratch/server.pid"
  wait
) &
server_pid=$!
export HYDRONIUM_LAB_URL=http://127.0.0.1:6196/lab/
export HYDRONIUM_LAB_FIXTURE="$app/src/Counter.luax"
for _ in {1..180}; do
  if curl --fail --silent "$HYDRONIUM_LAB_URL" >/dev/null; then break; fi
  sleep 1
done
if ! curl --fail --silent "$HYDRONIUM_LAB_URL" >/dev/null; then cat "$scratch/server.log"; fail "Lab did not start"; fi
node --test "$root/js/tests/lab_mixed.browser.test.mjs"
echo "mixed Lab packaged consumer gate passed"
