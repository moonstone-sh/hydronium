-- Backward-compatible facade. Prefer a focused capability for new code:
-- primitives (unpack/tointeger), loader (text compilation), diagnostics (debug).
local primitives = require("hydronium.compat.primitives")
local loader = require("hydronium.compat.loader")
local diagnostics = require("hydronium.compat.diagnostics")
---@type HydroniumCompat
return {
  unpack = primitives.unpack,
  tointeger = primitives.tointeger,
  load = loader.load,
  function_location = diagnostics.function_location,
  function_arity = diagnostics.function_arity,
}
