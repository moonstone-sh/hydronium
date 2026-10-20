$ErrorActionPreference = 'Stop'
$root = $env:GITHUB_WORKSPACE
$fixture = Join-Path $env:RUNNER_TEMP 'hydronium-windows-consumer'
New-Item -ItemType Directory -Force $fixture | Out-Null
# Export and install the candidate package, not a path dependency. This proves
# the published source archive contains the DLL and Moonstone projects the OS
# variants and native assets without a POSIX shell.
moon -C (Join-Path $root 'ink') sync --update
if ($LASTEXITCODE -ne 0) { throw 'Ink package environment failed' }
moon -C (Join-Path $root 'ink') exec -- ballad play partiture.lua
if ($LASTEXITCODE -ne 0) { throw 'Windows Ink artifact export failed' }
$registry = Join-Path $env:RUNNER_TEMP 'hydronium-windows-registry'
moon registry init --file $registry --name hydronium-windows-fixture
if ($LASTEXITCODE -ne 0) { throw 'Windows fixture registry initialization failed' }
$descriptor = Join-Path $root 'ink/dist/registry/package.toml'
$archive = (Get-ChildItem (Join-Path $root 'ink/dist/registry/*-source.tar.gz') | Select-Object -First 1).FullName
moon registry --file $registry publish --descriptor $descriptor --artifact $archive
if ($LASTEXITCODE -ne 0) { throw 'Windows fixture publication failed' }
$registryUri = [Uri]::new($registry).AbsoluteUri
$version = (Select-String -Path $descriptor -Pattern '^version = "([^"]+)"').Matches[0].Groups[1].Value
$manifest = @"
manifest_version = 2
[package]
name = "hydronium-windows-contract"
version = "0.1.0"
kind = "script"
[[registries]]
name = "fixture"
resolver = "moonstone"
url = "$registryUri"
priority = 100
[interpreter]
name = "luajit"
version = "2.1.0"
abi = "5.1"
[[dependencies]]
name = "hydronium/ink"
constraint = "=$version"
registry = "fixture"
role = "runtime"
[[dependencies]]
name = "moonstone/ballad"
constraint = "^0.4.7"
role = "runtime"
[[dependencies]]
name = "moonstone/clingy"
constraint = "^0.8.1"
role = "runtime"
[[dependencies]]
name = "moonstone/alter-jsonc"
constraint = "^0.2.0"
role = "runtime"
[[dependencies]]
name = "moonstone/valua"
constraint = "^0.3.0"
role = "runtime"
"@
[IO.File]::WriteAllText((Join-Path $fixture 'moonstone.toml'), $manifest, [Text.UTF8Encoding]::new($false))
moon -C $fixture sync --update
if ($LASTEXITCODE -ne 0) { throw 'Windows consumer sync failed' }
$exports = moon -C $fixture env --shell powershell
if ($LASTEXITCODE -ne 0) { throw 'Windows consumer exports failed' }
Invoke-Expression ($exports -join "`n")
Set-Location $root
$env:HYDRONIUM_NO_UPDATE_CHECK = '1'
# Shared rendering, signals, HMR, navigation and data primitives execute on
# Windows as well as the OS-specific terminal driver.
luajit tests/runner.lua `
  tests/signals/signals_spec.lua `
  tests/core/element_spec.lua tests/core/component_spec.lua `
  tests/core/reconciler_spec.lua tests/core/context_ref_spec.lua `
  tests/host/terminal_spec.lua tests/host/ink_session_spec.lua `
  tests/host/ink_hmr_spec.lua tests/host/terminal_background_spec.lua `
  query/tests/query_spec.lua virtual/tests/virtual_spec.lua `
  table/tests/table_spec.lua table/tests/remote_spec.lua `
  tests/router/router_spec.lua tests/router/url_spec.lua
if ($LASTEXITCODE -ne 0) { throw 'Windows shared framework contract failed' }
luajit tests/native/windows_smoke.lua
if ($LASTEXITCODE -ne 0) { throw 'Windows scaffolding and Yoga contract failed' }
luajit tests/native/windows_console.lua
if ($LASTEXITCODE -ne 0) { throw 'Windows native console contract failed' }

Set-Location $fixture
luajit (Join-Path $root 'tests/native/windows_supervision.lua')
if ($LASTEXITCODE -ne 0) { throw 'Windows process ownership contract failed' }
