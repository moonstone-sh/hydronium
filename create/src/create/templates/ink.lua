local ink = {}

function ink.files(opts)
  local project_name = opts.name or "my-hydronium-ink-app"
  local files = {}

  files["moonstone.toml"] = string.format([=[manifest_version = 2

[package]
name = "%s"
version = "0.1.0"
kind = "script"
description = "Interactive terminal UI built with Hydronium Ink"

[interpreter]
name = "luajit"
version = "2.1.0"
abi = "5.1"

[scripts]
run = "luajit run.lua"
lab = "moon exec --dev -- hydronium-lab dev"

[[dependencies]]
name = "hydronium/core"
constraint = "^0.2.0"
role = "runtime"

[[dependencies]]
name = "hydronium/ink"
constraint = "^0.5.0"
role = "runtime"

[[dependencies]]
name = "hydronium/luax"
constraint = "^0.2.0"
role = "runtime"

# Development-only workbench closure. The terminal app never imports these;
# `moon run lab` starts a separate loopback Meteorite process.
[[dependencies]]
name = "hydronium/lab"
constraint = "^0.2.0"
role = "dev"

[[dependencies]]
name = "hydronium/ink-lab"
constraint = "^0.2.0"
role = "dev"

[[dependencies]]
name = "hydronium/meteorite"
constraint = "^0.2.0"
role = "dev"

[[dependencies]]
name = "hydronium/lab-cli"
constraint = "^0.2.0"
role = "tool"

[[dependencies]]
name = "moonstone/meteorite"
constraint = "^0.2.8"
role = "tool"
]=], project_name)

  files[".gitignore"] = [[.moonstone/
*.log
]]

  files["run.lua"] = [[io.stdout:setvbuf("no")

local hydronium = require("hydronium")
local luax = require("hydronium_luax")
local render = require("hydronium_ink.render")
local hmr = require("hydronium.core.hmr")
local hmr_host = require("hydronium.core.hmr_host")
local family_loader = require("hydronium.core.family_loader")
local source_topology = require("hydronium.core.source_topology")
local source_inventory = require("hydronium.core.source_inventory")

local function read_file(path)
  local file, err = io.open(path, "r")
  if not file then
    error("Cannot read " .. path .. ": " .. tostring(err), 2)
  end
  local source = file:read("*a")
  file:close()
  return source
end

local info = debug.getinfo(1, "S")
local root = info.source:gsub("^@", ""):match("^(.*)[/\\][^/\\]+$") or "."

-- LUAX's hydronium target emits these runtime names. Modules still import
-- their explicit dependencies normally; these globals are compiler ABI.
_G.H = hydronium
_G.__luax = require("hydronium_luax.runtime")

-- Prefer Ballad's generated authority whenever it exists. Source-mode remains
-- useful before a first build, but it is only a fallback; no directory name
-- carries framework meaning in either path.
local function quote_shell(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function scan_paths(config)
  local paths = {}
  for _, source_root in ipairs(config.roots or {}) do
    local command = "find " .. quote_shell(root .. "/" .. source_root.path)
      .. " -type f \\( -name '*.lua' -o -name '*.luax' \\) -print"
    local process = assert(io.popen(command, "r"))
    for path in process:lines() do
      paths[#paths + 1] = path:sub(#root + 2)
    end
    assert(process:close(), "Hydronium Ink: source scan failed for " .. source_root.path)
  end
  table.sort(paths)
  return paths
end

local function source_records()
  local inventory_path = root .. "/.hydronium/source-inventory.lua"
  local file = io.open(inventory_path, "r")
  if file then
    file:close()
    return source_inventory.load(inventory_path).records
  end
  local config = assert(loadfile(root .. "/hydronium.sources.lua"))()
  return source_topology.resolve(config, scan_paths(config))
end

local function scan_inputs()
  local records = source_records()
  local inputs = {}
  for _, record in ipairs(records) do
    inputs[record.id] = {
      path = root .. "/" .. record.path, source = read_file(root .. "/" .. record.path),
      logical_path = record.path, transform = record.transform,
      update = record.update, effects = record.effects,
    }
  end
  return inputs
end

local function compile_inputs(inputs)
  local sources = {}
  for id, input in pairs(inputs) do
    if input.transform == "luax" then
      sources[id] = luax.compile(input.source, {
        filename = input.path, module_id = id, runtime = "hydronium", sourcemap = true,
      }).code
    elseif input.transform == "lua" then
      sources[id] = input.source
    else
      error("Hydronium Ink: unsupported transform `" .. tostring(input.transform) .. "` for " .. id)
    end
  end
  return sources
end

local function changed_ids(previous, current)
  local changed = {}
  for id, input in pairs(current) do
    local prior = previous[id]
    if not prior or prior.source ~= input.source or prior.logical_path ~= input.logical_path
      or prior.transform ~= input.transform or prior.update ~= input.update or prior.effects ~= input.effects then
      changed[id] = true
    end
  end
  for id in pairs(previous) do
    if not current[id] then changed[id] = true end
  end
  return changed
end

family_loader.enable()
local last_inputs = scan_inputs()
local sources = compile_inputs(last_inputs)
for id, source in pairs(sources) do
  hmr.install(id, source)
  -- Initial installation is also manifest-gated: an undeclared effect
  -- boundary may run normally, but cannot be live-replaced later.
  require("hydronium.core.module_graph").manage(id, { effects = last_inputs[id].effects })
end
  local App = require("app")

local next_poll = 0
local revision = 0
local updates = hmr_host.new()
local function poll_hmr()
  local now = require("hydronium_ink.clock").nowMs()
  if now < next_poll then return end
  next_poll = now + 150

  local current_inputs = scan_inputs()
  local changed = changed_ids(last_inputs, current_inputs)
  if next(changed) == nil then return end
  local ok, current_sources_or_error = pcall(compile_inputs, current_inputs)
  if not ok then
    io.stderr:write("\nHydronium Ink: refresh compile failed: " .. tostring(current_sources_or_error) .. "\n")
    return
  end
  -- A failed compilation deliberately leaves the previous snapshot intact:
  -- the live program stays running and the repaired source will be retried.
  local batch = {}
  local effects = {}
  for id in pairs(changed) do
    if not current_sources_or_error[id] then
      io.stderr:write("\nHydronium Ink: module removed (restart required): " .. id .. "\n")
      return
    end
    batch[id] = current_sources_or_error[id]
    effects[id] = current_inputs[id].effects
  end

  revision = revision + 1
  updates:queue_batch(batch, { revision = tostring(revision), effects = effects })
  -- onTick runs outside input dispatch and render, immediately before Ink
  -- flushes the terminal host. Every source queued during this turn is
  -- therefore committed as one revisioned batch at a safe host boundary.
  local replaced, result_or_error = pcall(updates.flush, updates, tostring(revision))
  if not replaced or result_or_error.outcome == "restart" or result_or_error.outcome == "rejected" or result_or_error.failed > 0 then
    io.stderr:write("\nHydronium Ink: refresh failed: " .. tostring(result_or_error) .. "\n")
    return
  end
  last_inputs = current_inputs

end

local result = render.render(hydronium.h(App), { onTick = poll_hmr })
io.stdout:write("\nExited: " .. tostring(result.exitReason) .. "\n")
]]

  files["hydronium.sources.lua"] = [[-- One source topology shared by development hosts and future build adapters.
-- `namespace` is a mechanical module prefix, not a framework convention.
-- Add roots, transform rules, or explicit entries to match your project.
return {
  roots = {
    { path = "src", namespace = "app", target = "client", update = "hot", effects = "safe",
      transforms = { lua = "lua", luax = "luax" } },
  },
  -- A public entry name is explicit. Other files retain their mechanical
  -- ids: src/features/auth/Login.luax -> app.features.auth.Login.
  entries = {
    { id = "app", path = "src/app.luax" },
  },
}
]]

  files["src/app.luax"] = [[local hydronium = require("hydronium")
local ink = require("hydronium_ink")
local hooks = require("hydronium_ink.hooks")

-- `scope` is explicit so the LUAX refresh transform can route the signal
-- through this component instance's persistent RefreshRegistry.
return function(_, scope)
  local count, setCount = hydronium.signal(0)
  local exit = hooks.useApp().exit

  hooks.useInput(function(input, key)
    if input == "q" or (key.ctrl and input == "c") then
      exit()
    elseif input == "+" or key.upArrow then
      setCount(function(value) return value + 1 end)
    elseif input == "-" or key.downArrow then
      setCount(function(value) return value - 1 end)
    elseif input == "r" then
      setCount(0)
    end
  end)

  return function()
    return <ink.Box flexDirection="column" borderStyle="single" borderColor="cyan" paddingX={1}>
      <ink.Text bold={true} color="cyan">Hydronium Ink Counter</ink.Text>
      <ink.Newline />
      <ink.Text>{"Count: " .. count()}</ink.Text>
      <ink.Newline />
      <ink.Text dimColor={true}>+/- or arrows: change   r: reset   q: quit</ink.Text>
    </ink.Box>
  end
end
]]

  files["src/App.stories.luax"] = [[local lab = require("hydronium_lab")
local App = require("app")

-- This browser workbench story is separate from the terminal program. Add
-- more variants here or colocate stories beside any Ink component.
return lab.collection({
  title = "App",
  component = App,
  stories = {
    default = {},
  },
})
]]

  files["README.md"] = string.format([[# %s

An interactive terminal counter built with Hydronium Ink, LUAX, and the real
terminal renderer. While it is running, edits to `src/app.luax` are compiled
and hot-swapped in the existing LuaJIT VM, preserving compatible signal state.

Source topology is declared in `hydronium.sources.lua`, rather than inferred
from directory names. The starter mapping makes `src/features/auth/Login.luax`
available as `require("app.features.auth.Login")`; `app` is an explicit entry
for `src/app.luax`. Add roots or change namespaces to fit components, routes,
features, layers, or any other project shape. Removing a loaded module is a
deliberate restart boundary.

## Run

```bash
moon sync
moon run run
```

## Component Lab

The browser Lab is a development companion: it starts a separate loopback
Meteorite server and is never imported by `run.lua` or included in the terminal
application's release closure.

```bash
moon run lab
```

Open the printed local URL. `src/App.stories.luax` is the first story; add
`*.stories.luax` or `*.stories.lua` beside components as the application grows.
The Lab preserves the selected story, terminal dimensions, and color capability
across successful updates. `moon run run` remains the real interactive TTY app.

Controls:

- `+` / Up: increment
- `-` / Down: decrement
- `r`: reset
- `q` or Ctrl-C: quit

Hydronium Ink requires LuaJIT 2.1 because its terminal layout engine uses FFI.
Run the application in an interactive terminal on macOS or glibc Linux (arm64
or x86-64); the current TTY backend does not support Windows.
]], project_name)

  return files
end

return ink
