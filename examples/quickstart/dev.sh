#!/bin/sh
# Friendly dev-server banner for the quickstart example.
#
# This does NOT replace or wrap Meteorite's own dev server -- it execs the
# real `meteorite dev` invocation below and gets out of the way. The only
# thing added is the banner, printed from a background subshell that waits
# until the server genuinely answers, so the URL is never announced before
# it actually works (the first run has to compile the Zig server, which
# takes a while). Meteorite still prints its own
# "Meteorite dev server: http://127.0.0.1:PORT ..." line as usual.

PORT=8080

(
  while ! curl -sf -o /dev/null "http://127.0.0.1:$PORT/api/health" 2>/dev/null; do
    sleep 0.5
  done
  printf '\n  \033[32m\xe2\x9e\x9c\033[0m  Hydronium app up and running on \033[36mhttp://localhost:%s/\033[0m\n\n' "$PORT"
) &

exec moon exec --dev meteorite dev \
  --mode hybrid_dev \
  --backend fast_http \
  --lua-root .moonstone/env/libexec/luajit
