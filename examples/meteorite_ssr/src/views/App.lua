--[[
  Compiles views/App.luax on demand and returns the component function.

  This lives in its own requirable module (not a `main.lua` upvalue)
  because Meteorite's hybrid build mode "lifts" each inline Lua route
  handler: it extracts the handler function's own source text and reloads
  it standalone at request time, so a handler cannot close over locals
  from outside its own body. `require("views.App")` is a plain call any
  handler body can make; a captured upvalue from main.lua's top level
  cannot.
--]]

local luax = require("hydronium_luax")

local function load_luax(filepath)
  local f = assert(io.open(filepath, "r"), "Cannot open .luax file: " .. filepath)
  local source = f:read("*a")
  f:close()

  local compiled = luax.compile(source, {
    filename = filepath,
    runtime = "hydronium",
    development = false,
  })

  local load_fn = loadstring or load
  local chunk, err = load_fn(compiled.code, "@" .. filepath)
  if not chunk then
    error("Syntax error loading compiled .luax [" .. filepath .. "]: " .. tostring(err))
  end
  return chunk()
end

return load_luax("views/App.luax")
