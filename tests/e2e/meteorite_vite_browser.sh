#!/usr/bin/env bash
# CI supervisor for the browser gates that need both the compiled Meteorite
# application and, for dual HMR, a real Vite dev server.  Keeping process
# ownership here makes cleanup reliable and keeps the test files themselves
# focused on behavior.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
moon=${MOON_BIN:-moon}
example="$root/examples/meteorite_ssr"
vite_example="$root/js/examples/islands-tailwind"
server_pid=""
vite_pid=""

cleanup() {
  for pid in "$vite_pid" "$server_pid"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      # An idle Meteorite server only notices SIGTERM between connections;
      # a bare `wait` on it blocks forever. Give it a moment, then force it.
      kill "$pid" 2>/dev/null || true
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5
      done
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
}
trap cleanup EXIT

fail() { echo "Meteorite/Vite browser gate: $*" >&2; exit 1; }
wait_http() {
  local url=$1 label=$2
  for _ in $(seq 1 150); do
    if curl --fail --silent "$url" >/dev/null; then return 0; fi
    sleep 0.1
  done
  fail "$label did not become ready at $url"
}

[[ -x "$moon" ]] || fail "MOON_BIN is not executable: $moon"
export PATH="$(dirname "$moon"):$PATH"

# The production gate consumes Vite's hashed build through Ballad, then must
# prove the resulting Meteorite binary has no runtime Vite dependency.
(cd "$vite_example" && pnpm exec vite build)
(
  cd "$example"
  # Not an orbit member: nothing else syncs this example's environment. Not
  # --locked: the committed lock may lack this machine's target profile.
  "$moon" sync
  "$moon" run package
  "$moon" run graph
  # `hybrid_dev` is a dev-server profile, not a build mode.  The packaged
  # compiler emits a runnable server for the `hybrid` build mode.
  "$moon" exec --dev -- meteorite build --mode hybrid --backend fast_http
  exec ./dist/server
) >"$root/.meteorite-vite-ci-server.log" 2>&1 &
server_pid=$!
wait_http http://127.0.0.1:8080/prod-island "Meteorite server"
node --test "$vite_example/tests/prod-island.test.mjs"

# The dual gate deliberately runs Vite only after the production assertion;
# prod-island.test refuses to pass if :5174 is listening.
(cd "$vite_example" && exec pnpm exec vite --port 5174 --strictPort --host 127.0.0.1) \
  >"$root/.meteorite-vite-ci-vite.log" 2>&1 &
vite_pid=$!
wait_http http://127.0.0.1:5174/ "Vite dev server"
node --test "$vite_example/tests/dual-hmr.test.mjs"
