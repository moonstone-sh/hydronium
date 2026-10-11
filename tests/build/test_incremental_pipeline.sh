#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
BALLAD_ROOT=${BALLAD_ROOT:-"$ROOT/../ballad"}
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
LUA_PATH="$BALLAD_ROOT/src/?.lua;$BALLAD_ROOT/src/?/init.lua;"
for src in "$ROOT"/*/src; do
  LUA_PATH="$LUA_PATH$src/?.lua;$src/?/init.lua;"
done
export HYDRONIUM_FRAMEWORK_ROOT="$ROOT/.moonstone/env/share/lua/5.1"
export LUA_PATH="$LUA_PATH$HYDRONIUM_FRAMEWORK_ROOT/?.lua;$HYDRONIUM_FRAMEWORK_ROOT/?/init.lua;;"
cd "$WORK_DIR"
"${LUA_BIN:-luajit}" "$ROOT/tests/build/incremental_pipeline.lua"
