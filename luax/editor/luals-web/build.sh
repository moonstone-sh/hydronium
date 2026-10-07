#!/usr/bin/env bash
# Builds lua-language-server for the browser:
#
#   dist/luals.mjs + dist/luals.wasm   Lua 5.5.1 + lpeglabel + the bridge (luals_web.c)
#   dist/luals-bundle.bin              LuaLS's Lua sources, en-us strings and stdlib
#                                      template, Hydronium's LuaLS plugin and types
#   dist/shim.lua                      the OS stand-in, loaded first
#
# Inputs are pinned and checksummed; the result is what public/js/luals-worker.js
# in a site loads. Needs emcc (Emscripten 6.0.x) and node.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
cache="$here/.cache"
dist="$here/dist"
mkdir -p "$cache" "$dist"

LUA_URL=https://www.lua.org/ftp/lua-5.5.1.tar.gz
LUA_SHA=1c4b4068d67061f2a2231ad2b5422e77acea1487ea9890f6320af614f4373dce
LPEGLABEL_REV=912b0b9e8641074408ffc2259e069b188e0c717b
LPEGLABEL_URL=https://github.com/sqmedeiros/lpeglabel/archive/$LPEGLABEL_REV.tar.gz
LPEGLABEL_SHA=f30f8039b89a571bdf450d1b82727ddbb3905e58b205ddd0421fad50983b991f
LUALS_VERSION=3.19.1
LUALS_URL=https://github.com/LuaLS/lua-language-server/releases/download/$LUALS_VERSION/lua-language-server-$LUALS_VERSION-linux-x64.tar.gz
LUALS_SHA=e9235d2d72ef55bc41cf8c99cda2ed64777682024b4bb81f5dea425060c5cbb8

fetch() { # url sha file
  local file="$cache/$3"
  if [[ ! -f "$file" ]] || [[ "$(shasum -a 256 "$file" | cut -d' ' -f1)" != "$2" ]]; then
    curl -fsSL --retry 5 -C - -o "$file" "$1" || curl -fsSL --retry 5 -o "$file" "$1"
  fi
  [[ "$(shasum -a 256 "$file" | cut -d' ' -f1)" == "$2" ]] || { echo "checksum mismatch: $3" >&2; exit 1; }
}
fetch "$LUA_URL" "$LUA_SHA" lua-5.5.1.tar.gz
fetch "$LPEGLABEL_URL" "$LPEGLABEL_SHA" lpeglabel-$LPEGLABEL_REV.tar.gz
fetch "$LUALS_URL" "$LUALS_SHA" lua-language-server-$LUALS_VERSION.tar.gz

src="$cache/src"
rm -rf "$src" && mkdir -p "$src/luals"
tar xzf "$cache/lua-5.5.1.tar.gz" -C "$src"
tar xzf "$cache/lpeglabel-$LPEGLABEL_REV.tar.gz" -C "$src"
tar xzf "$cache/lua-language-server-$LUALS_VERSION.tar.gz" -C "$src/luals"

command -v emcc >/dev/null || { echo "emcc is required" >&2; exit 2; }
lua_c=$(ls "$src"/lua-5.5.1/src/*.c | grep -vE '/(lua|luac|onelua)\.c$')
# shellcheck disable=SC2086
emcc -O2 -DLUA_USE_POSIX -I"$src/lua-5.5.1/src" "$here/luals_web.c" $lua_c "$src"/lpeglabel-$LPEGLABEL_REV/*.c \
  -o "$dist/luals.mjs" \
  -sMODULARIZE=1 -sEXPORT_ES6=1 -sENVIRONMENT=web,worker,node -sFILESYSTEM=0 \
  -sALLOW_MEMORY_GROWTH=1 -sINITIAL_MEMORY=64MB -sSTACK_SIZE=4MB \
  -sEXPORTED_FUNCTIONS=_luals_init,_luals_run,_luals_invoke,_luals_result,_luals_result_len,_malloc,_free \
  -sEXPORTED_RUNTIME_METHODS=UTF8ToString,HEAPU8

node "$here/build-bundle.mjs" "$src/luals" "$repo" "$dist/luals-bundle.bin"
cp "$here/shim.lua" "$dist/shim.lua"
printf '%s\n' "lua-language-server $LUALS_VERSION, Lua 5.5.1, lpeglabel $LPEGLABEL_REV" > "$dist/VERSION"
( cd "$dist" && shasum -a 256 luals.mjs luals.wasm luals-bundle.bin shim.lua )
