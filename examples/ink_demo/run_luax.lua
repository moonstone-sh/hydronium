--[[
  Hydronium Ink demo runner -- .luax version. Compiles demo.luax through
  the real hydronium_luax compiler (runtime = "hydronium", the real
  execution backend, not the LuaLS virtual-source projection) and drives
  it through the same terminal Host adapter run.lua uses directly, so the
  two demos' captured output can be compared byte-for-byte -- see
  docs/LUAX_HOST_TYPE_AUTHORING.md's "Verification" section.

    luajit examples/ink_demo/run_luax.lua [ticks]

  Same pty-capture verification recipe as run.lua (see that file's own
  doc comment and docs/HYDRONIUM_INK_TERMINAL_HOST.md).
--]]

package.path = "core/src/?.lua;core/src/?/init.lua;ink/src/?.lua;ink/src/?/init.lua;luax/src/?.lua;luax/src/?/init.lua;./?.lua;./?/init.lua;" .. package.path

io.stdout:setvbuf("no") -- see run.lua's identical setvbuf call for why

local hydronium = require("hydronium")
local luax = require("hydronium_luax")
local reconcilerModule = require("hydronium.core.reconciler")
local terminalHostModule = require("hydronium_ink.host.terminal")

local function read_file(path)
  local f, err = io.open(path, "r")
  if not f then error("Cannot read file " .. path .. ": " .. tostring(err), 2) end
  local content = f:read("*a")
  f:close()
  return content
end

local src = read_file("examples/ink_demo/demo.luax")
local compiled = luax.compile(src, {
  filename = "demo.luax",
  runtime = "hydronium",
  sourcemap = true,
})

-- __index = _G lets the compiled chunk's ordinary Lua (require, tostring,
-- ...) resolve normally. The real (non-virtual) "hydronium" runtime
-- backend's generated code references both `H` (createElement/Fragment)
-- and `__luax` (spread/fragment-children helpers) as bare globals --
-- confirmed by matching examples/showcase/run.lua's own shared_env,
-- which injects the identical pair.
local shared_env = setmetatable({
  H = hydronium,
  __luax = require("hydronium_luax.runtime"),
}, { __index = _G })

local chunk, load_err = load(compiled.code, "demo.luax", "t", shared_env)
if not chunk then
  error("Failed to load compiled demo.luax: " .. tostring(load_err) .. "\nCode:\n" .. compiled.code)
end

-- demo.luax's own top-level `return function(count) ... end`
local renderInk = chunk()

local host = terminalHostModule.createTerminalHost()
local root = host.getRoot()
local reconciler = reconcilerModule.Reconciler.new(host)

local count, setCount = hydronium.signal(0)

local function App()
  return function()
    return renderInk(count())
  end
end

reconciler:mount(hydronium.h(App), root)
host.flush()

local ticks = tonumber(arg and arg[1]) or 1000000
for i = 1, ticks do
  os.execute("sleep 0.3")
  setCount(i)
  host.flush()
end
