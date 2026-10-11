#!/bin/sh
# Fresh CLI scaffold, ordinary package installation, SSR and browser closure.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
moon registry create "$WORK_DIR/registry" candidates
for member in core auth dom luax build query table; do
  (cd "$ROOT/$member" && moon exec -- ballad play partiture.lua)
  moon registry push "$WORK_DIR/registry" --descriptor "$ROOT/$member/dist/registry/package.toml" --blob "$ROOT/$member"/dist/registry/*-source.tar.gz
done
(cd "$ROOT/create" && moon exec -- luajit src/main.lua "$WORK_DIR/consumer" --template ssr --name candidate-consumer --package-manager bun --no-install --no-git --yes)
cd "$WORK_DIR/consumer"
moon registry add candidates "file://$WORK_DIR/registry" --default
for member in core auth dom luax build query table; do
  name=$(sed -n 's/^name = "\(.*\)"/\1/p' "$ROOT/$member/moonstone.toml" | head -1)
  version=$(sed -n 's/^version = "\(.*\)"/\1/p' "$ROOT/$member/moonstone.toml" | head -1)
  moon add "candidates:$name@$version" --role runtime --no-sync
done
moon sync
mkdir -p src/components
cat > src/components/AuthProbe.lua <<'LUA'
local H=require('hydronium')
local auth=require('hydronium_auth')
local d=require('hydronium_dom').d
return function()
 local flow=auth.createFlow({transport=function(_,_,done)done(nil,{step='ready'})end})
 flow:submit('probe',{})
 return d.span(nil,function()return 'Auth '..flow.state().step end)
end
LUA
# Make the optional package part of the generated app's browser closure.
{ printf '%s\n' 'local AuthProbe=require("components.AuthProbe")'; cat src/views/App.luax; } > src/views/App.luax.tmp
mv src/views/App.luax.tmp src/views/App.luax
cat > verify.lua <<'LUA'
package.path='src/?.lua;src/?/init.lua;'..package.path
require('hydronium_luax').loader.install()
local H=require('hydronium')
local html=require('hydronium_dom.server').render_to_string(H.h(require('components.AuthProbe')))
assert(html:find('Auth ready',1,true),html)
print('PASS: packaged Auth renders in a fresh CLI-generated SSR project')
LUA
moon exec -- luajit verify.lua
moon exec -- ballad play build.partiture.lua
grep -q 'hydronium_auth' .hydronium/client/runtime-*.lua
moon lock verify --json
printf '%s\n' 'PASS: fresh scaffold resolves seven candidate packages and bundles standalone Auth'
