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

[[dependencies]]
name = "moonstone/hydronium"
constraint = "^0.1.0"
role = "runtime"

[[dependencies]]
name = "moonstone/hydronium-ink"
constraint = "^0.1.1"
role = "runtime"

[[dependencies]]
name = "moonstone/hydronium-luax"
constraint = "^0.1.0"
role = "runtime"
]=], project_name)

  files[".gitignore"] = [[.moonstone/
*.log
]]

  files["run.lua"] = [[io.stdout:setvbuf("no")

local hydronium = require("hydronium")
local luax = require("hydronium_luax")
local render = require("hydronium_ink.render")
local hmr = require("hydronium.core.hmr")
local family_loader = require("hydronium.core.family_loader")

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
local filename = root .. "/src/App.luax"
local function compile_app()
  return luax.compile(read_file(filename), {
    filename = filename,
    runtime = "hydronium",
    sourcemap = true,
  }).code
end

-- LUAX's hydronium target emits these runtime names. Modules still import
-- their explicit dependencies normally; these globals are compiler ABI.
_G.H = hydronium
_G.__luax = require("hydronium_luax.runtime")

local module_id = "app"
family_loader.enable()
local source = compile_app()
hmr.install(module_id, source)
local App = require(module_id)

local last_source = read_file(filename)
local next_poll = 0
local function poll_hmr()
  local now = require("hydronium_ink.clock").nowMs()
  if now < next_poll then return end
  next_poll = now + 150

  local current = read_file(filename)
  if current == last_source then return end
  -- Attempt each saved source once. A syntax error remains on screen while
  -- the previous component keeps running; the next edit gets a fresh try.
  last_source = current

  local ok, compiled_or_error = pcall(compile_app)
  if not ok then
    io.stderr:write("\nHydronium Ink: refresh compile failed: " .. tostring(compiled_or_error) .. "\n")
    return
  end

  local replaced, result_or_error = pcall(hmr.replace, module_id, compiled_or_error)
  if not replaced or result_or_error.failed > 0 then
    io.stderr:write("\nHydronium Ink: refresh failed: " .. tostring(result_or_error) .. "\n")
    return
  end

end

local result = render.render(hydronium.h(App), { onTick = poll_hmr })
io.stdout:write("\nExited: " .. tostring(result.exitReason) .. "\n")
]]

  files["src/App.luax"] = [[local hydronium = require("hydronium")
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

  files["README.md"] = string.format([[# %s

An interactive terminal counter built with Hydronium Ink, LUAX, and the real
terminal renderer. While it is running, edits to `src/App.luax` are compiled
and hot-swapped in the existing LuaJIT VM, preserving compatible signal state.

## Run

```bash
moon sync
moon run run
```

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
