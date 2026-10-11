#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
for member in core auth query table; do
  (cd "$ROOT/$member" && moon exec -- ballad play partiture.lua)
  mkdir -p "$WORK_DIR/$member"
  tar -xzf "$ROOT/$member"/dist/registry/*-source.tar.gz -C "$WORK_DIR/$member"
done
for file in core/types/application.d.lua auth/types/auth.d.lua table/types/remote.d.lua; do
  test -f "$WORK_DIR/$file"
done
test ! -f "$WORK_DIR/core/src/hydronium/auth.lua"
export LUA_PATH="$WORK_DIR/auth/src/?.lua;$WORK_DIR/auth/src/?/init.lua;$WORK_DIR/core/src/?.lua;$WORK_DIR/core/src/?/init.lua;$WORK_DIR/query/src/?.lua;$WORK_DIR/query/src/?/init.lua;$WORK_DIR/table/src/?.lua;$WORK_DIR/table/src/?/init.lua"
export LUA_CPATH=""
cd "$WORK_DIR"
cat > smoke.lua <<'LUA'
local config=require('hydronium.config').require({port={kind='integer',min=1,max=65535}},{port='8080'})
assert(config.port==8080)
local auth=require('hydronium_auth').createFlow({transport=function(_,_,done)done(nil,{step='otp'})end})
auth:submit('email',{});assert(auth.state().step=='otp');auth:dispose()
local remote=require('hydronium_table.remote').create({client=require('hydronium_query').createClient(),key='isolated',
 query=function(_,_,done)done(nil,{rows={{id=1}},total=1})end})
assert(remote.total()==1 and #remote.model:getRows()==1);remote:dispose()
print('PASS: isolated Core, Auth, Query and Table source artifacts with declarations')
LUA

"${LUA_BIN:-luajit}" smoke.lua
# Exercise Moonstone's package resolver/materializer as a normal consumer too.
moon registry create "$WORK_DIR/registry" candidates
for member in core auth query table; do
  moon registry push "$WORK_DIR/registry" --descriptor "$ROOT/$member/dist/registry/package.toml" --blob "$ROOT/$member"/dist/registry/*-source.tar.gz
done
mkdir -p "$WORK_DIR/consumer"
cat > "$WORK_DIR/consumer/moonstone.toml" <<EOF
manifest_version = 2
[package]
name = "test/auth-consumer"
version = "0.1.0"
kind = "script"
[interpreter]
name = "luajit"
version = "2.1.0"
abi = "5.1"
[[registries]]
name = "candidates"
resolver = "moonstone"
path = "$WORK_DIR/registry"
priority = 10
[[dependencies]]
name = "hydronium/auth"
constraint = "=0.1.0"
role = "runtime"
[[dependencies]]
name = "hydronium/query"
constraint = "=$(sed -n 's/^version = "\(.*\)"/\1/p' "$ROOT/query/moonstone.toml" | head -1)"
role = "runtime"
[[dependencies]]
name = "hydronium/table"
constraint = "=$(sed -n 's/^version = "\(.*\)"/\1/p' "$ROOT/table/moonstone.toml" | head -1)"
role = "runtime"
EOF
cp "$WORK_DIR/smoke.lua" "$WORK_DIR/consumer/main.lua"
unset LUA_PATH LUA_CPATH
cd "$WORK_DIR/consumer"
moon sync
moon exec -- luajit main.lua
moon lock verify --json
printf '%s\n' 'PASS: normal Moonstone consumer resolves exported Auth, Core, Query and Table'
