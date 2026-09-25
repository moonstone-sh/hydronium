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
    # A Meteorite server only notices SIGTERM between connections, so an idle
    # one keeps running; a bare `wait` then blocks forever (this hung CI for
    # the full job timeout). Give it a moment, then force it.
    kill "$server_pid" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$server_pid" 2>/dev/null || break
      sleep 0.5
    done
    kill -9 "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$scratch"
}
trap cleanup EXIT

fail() { echo "consumer gate: $*" >&2; exit 1; }

# Registries with equal priority resolve in no guaranteed order (Moonstone
# collects them from a hash map), and `registry add --default` is currently a
# no-op. Without an explicit priority the public registry can win, and this
# gate silently tests the last PUBLISHED Hydronium instead of this checkout.
prefer_local_registry() {
  "$moon" registry add "$registry_name" "file://$registry"
  awk -v want="\"$registry_name\"" '
    /^\[\[registries\]\]/ { current = "" }
    /^name = / { current = $3 }
    /^priority = / && current == want { $0 = "priority = 100" }
    { print }
  ' moonstone.toml > moonstone.toml.tmp && mv moonstone.toml.tmp moonstone.toml
  grep -q 'priority = 100' moonstone.toml || fail "could not prioritize the local registry"
}

# `priority` only governs which registry Moonstone tries first for a
# dependency whose registry identity is genuinely unset. It is NOT consulted
# for the overwhelmingly common case: an unprefixed package spec (`moon add
# hydronium/create`) or an unprefixed `[[dependencies]]` manifest entry
# (exactly what every `hydronium-create` template writes for hydronium/core,
# hydronium/dom, hydronium/luax, hydronium/cli, ...). Moonstone treats
# "no explicit registry" on those as the literal registry identity
# "moonstone" -- the name of the real public default registry, not "search
# every same-kind registry by priority" -- so no priority setting on a
# differently-named local registry can ever be reached for them. See the
# fix commit's report for the exact code path
# (RegistryProvider.get_artifact's `requested_registry` filtering in
# moonstone's src/core/resolution/provider/graph_provider.zig).
#
# Work around this from the consumer side by rewriting every unprefixed
# hydronium/* dependency line in a manifest to carry an explicit
# `registry = "<registry_name>"`, which Moonstone does respect.
pin_hydronium_deps_to_local_registry() {
  awk -v want="$registry_name" '
    function flush() {
      if (in_dep && name ~ /^hydronium\// && !printed_registry) print "registry = \"" want "\""
      in_dep = 0; name = ""; printed_registry = 0
    }
    /^\[/ {
      flush()
      if ($0 == "[[dependencies]]") in_dep = 1
      print
      next
    }
    in_dep && /^name[ \t]*=/ {
      name = $0
      sub(/^name[ \t]*=[ \t]*"/, "", name)
      sub(/"[ \t]*$/, "", name)
      print
      next
    }
    in_dep && /^registry[ \t]*=/ { printed_registry = 1; print; next }
    { print }
    END { flush() }
  ' moonstone.toml > moonstone.toml.tmp && mv moonstone.toml.tmp moonstone.toml
}

# shellcheck source=lib/local_registry.sh
source "$root/tests/e2e/lib/local_registry.sh"
[[ -x "$moon" ]] || fail "MOON_BIN is not executable: $moon"
[[ -d "$release_root" ]] || fail "package release is missing: $release_root (run ballad export first)"

# Generated project scripts invoke `moon` themselves.  Keep those nested
# invocations on the exact CLI under test instead of silently picking up an
# older user-global installation from PATH.
export PATH="$(dirname "$moon"):$PATH"

# A registry push copies the descriptor and blob into a registry-shaped tree;
# it is intentionally not a path dependency or a link-store registration.
# Exported dependency descriptors retain the `hydronium` registry identity.
# Give the disposable file registry that same name so the gate validates the
# actual published closure instead of falling through to an older remote
# Hydronium registry for transitive packages.
registry_name=hydronium
"$moon" registry create "$registry" "$registry_name"
descriptor_count=0
create_descriptor_count=0
while IFS= read -r descriptor; do
  descriptor_count=$((descriptor_count + 1))
  if grep -qx 'name = "hydronium/create"' "$descriptor"; then
    create_descriptor_count=$((create_descriptor_count + 1))
  fi
  package_dir=$(dirname "$descriptor")
  blob=$(find "$package_dir" -maxdepth 1 -type f -name '*.tar.gz' -print -quit)
  [[ -n "$blob" ]] || fail "no artifact beside exported descriptor: $descriptor"
  rewritten="$scratch/$(echo "$descriptor" | tr '/' '_').package.toml"
  rewrite_hydronium_deps "$descriptor" "$rewritten" "$registry_name"
  "$moon" registry push "$registry" --descriptor "$rewritten" --blob "$blob"
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
  prefer_local_registry
  # Explicit registry prefix: an unprefixed `hydronium/create` resolves the
  # literal "moonstone" registry identity regardless of priority (see
  # prefer_local_registry's comment above), which is exactly how this gate
  # kept silently testing the last published Hydronium.
  "$moon" add "$registry_name:hydronium/create"
  "$moon" exec -- hydronium-create "$app" --template islands --name consumer-islands
)

(
  cd "$app"
  prefer_local_registry
  pin_hydronium_deps_to_local_registry
  "$moon" sync
  "$moon" sync --locked

  # Assert every hydronium/* package this run's export produced was actually
  # what the app's lock resolved -- not merely that the sync commands above
  # exited 0. A regression here (Moonstone or gate) would otherwise resurface
  # only as a mystifyingly stale runtime behavior in the built app, exactly
  # like the bug this gate was silently missing before this fix.
  expected_versions="$scratch/hydronium-expected-versions.txt"
  awk '
    /^\[\[package\]\]/ { name = ""; version = "" }
    /^name[ \t]*=/ { name = $0; sub(/^name[ \t]*=[ \t]*"/, "", name); sub(/"[ \t]*$/, "", name) }
    /^version[ \t]*=/ { version = $0; sub(/^version[ \t]*=[ \t]*"/, "", version); sub(/"[ \t]*$/, "", version) }
    name ~ /^hydronium\// && version != "" { print name "\t" version; name = ""; version = "" }
  ' "$registry/index.toml" | sort -u >"$expected_versions"
  [[ -s "$expected_versions" ]] || fail "could not derive expected hydronium/* versions from the local registry index"

  lock_versions="$scratch/hydronium-lock-versions.txt"
  awk '
    function flush() {
      if (name ~ /^hydronium\//) print name "\t" version "\t" registry
      name = ""; version = ""; registry = ""
    }
    /^\[\[package\]\]/ || /^\[\[realization\]\]/ { flush() }
    /^name[ \t]*=/ { name = $0; sub(/^name[ \t]*=[ \t]*"/, "", name); sub(/"[ \t]*$/, "", name) }
    /^version[ \t]*=/ { version = $0; sub(/^version[ \t]*=[ \t]*"/, "", version); sub(/"[ \t]*$/, "", version) }
    /^registry[ \t]*=/ { registry = $0; sub(/^registry[ \t]*=[ \t]*"/, "", registry); sub(/"[ \t]*$/, "", registry) }
    END { flush() }
  ' moonstone.lock | sort -u >"$lock_versions"

  [[ -s "$lock_versions" ]] || fail "moonstone.lock has no hydronium/* packages at all"

  verified=0
  while IFS=$'\t' read -r actual_name actual_version actual_registry; do
    expected_version=$(awk -F'\t' -v n="$actual_name" '$1 == n { print $2; found = 1 } END { if (!found) exit 1 }' "$expected_versions") \
      || fail "moonstone.lock resolved $actual_name@$actual_version, which is not among this run's exported packages"
    [[ "$actual_registry" == "$registry_name" ]] \
      || fail "package $actual_name resolved from registry '$actual_registry' (version $actual_version), expected it from the local exported registry '$registry_name'"
    [[ "$actual_version" == "$expected_version" ]] \
      || fail "package $actual_name resolved to version $actual_version from registry '$actual_registry', expected the exported version $expected_version"
    verified=$((verified + 1))
  done <"$lock_versions"
  echo "consumer gate: verified $verified hydronium/* package(s) resolved from the local exported registry at their exported versions"

  # Every type library the scaffold points LuaLS at must actually have been
  # installed by `moon sync` (packages ship them as `collect.assets`, which
  # Moonstone materializes under .moonstone/env/libexec/<pkg>/). Without this
  # a green run proved nothing: a Moonstone that ignores assets leaves the
  # editor paths dangling and everything else still passes.
  [[ -f .luarc.json ]] || fail "scaffold did not write .luarc.json"
  type_paths=$(grep -oE '\.moonstone/env/libexec/[^"]+' .luarc.json | sort -u)
  [[ -n "$type_paths" ]] || fail ".luarc.json lists no installed type libraries"
  while IFS= read -r type_path; do
    [[ -d "$type_path" ]] || fail "type library $type_path referenced by .luarc.json was not installed"
    [[ -n "$(find "$type_path" -name '*.lua' -print -quit)" ]] || fail "type library $type_path is empty"
  done <<<"$type_paths"

  # The application must be materialized from package artifacts, not be able
  # to fall through to this repository via an accidentally inherited path.
  if grep -rnF "$root" .moonstone moonstone.lock; then
    fail "consumer environment references this Hydronium checkout"
  fi
  if grep -nE 'constraint = "path:|registry = "path"' moonstone.toml moonstone.lock; then
    fail "consumer manifest or lock retained a path dependency"
  fi

  # Vite templates build their stylesheet with the project's own JS toolchain
  # (the next steps hydronium-create prints); run it as a user would, before
  # the server build.
  if [[ -f package.json ]]; then
    npm install --no-audit --no-fund
    npm run build
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
grep -q 'consumer-islands' "$scratch/index.html" || fail "SSR response lacks scaffolded application markup"

HYDRONIUM_CONSUMER_URL=http://127.0.0.1:8080 HYDRONIUM_CONSUMER_LOG="$scratch/server.log" \
  bash -lc "$browser_gate"

echo "consumer gate passed: exported registry -> scaffold -> locked sync -> build -> browser"
