#!/bin/sh
# Check the package, without workspace source paths masking missing members.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' "$ROOT/luax/moonstone.toml" | head -1)
ARTIFACT=${1:-"$ROOT/luax/dist/registry/luax-$VERSION-source.tar.gz"}
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
tar -xzf "$ARTIFACT" -C "$WORK_DIR"
diff -r "$ROOT/luax/src" "$WORK_DIR/src"
cd "$WORK_DIR"
LUA_PATH="$WORK_DIR/src/?.lua;$WORK_DIR/src/?/init.lua;;" "${LUA_BIN:-luajit}" -e '
 local luax=require("hydronium_luax")
 assert(luax.loader)
 assert(require("hydronium_luax.dialects").of("example.luax")=="luax")
 assert(require("hydronium_luax.markdown"))
 print("PASS: isolated LUAX artifact closure and imports")
'
