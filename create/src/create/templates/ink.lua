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
name = "hydronium"
constraint = "^0.1.0"
role = "runtime"

[[dependencies]]
name = "hydronium-ink"
constraint = "^0.1.1"
role = "runtime"

[[dependencies]]
name = "hydronium-luax"
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
local compiled = luax.compile(read_file(filename), {
  filename = filename,
  runtime = "hydronium",
  sourcemap = true,
})

local environment = setmetatable({
  H = hydronium,
  hydronium = hydronium,
  __luax = require("hydronium_luax.runtime"),
}, { __index = _G })

local chunk, load_err = load(compiled.code, "@" .. filename, "t", environment)
if not chunk then
  error("Failed to load compiled App.luax: " .. tostring(load_err))
end

local App = chunk()
local result = render.render(hydronium.h(App))
io.stdout:write("\nExited: " .. tostring(result.exitReason) .. "\n")
]]

  files["src/App.luax"] = [[local hydronium = require("hydronium")
local ink = require("hydronium_ink")
local hooks = require("hydronium_ink.hooks")

return function()
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
terminal renderer.

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
