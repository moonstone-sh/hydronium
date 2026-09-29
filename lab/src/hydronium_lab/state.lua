-- Reactive story state shared by renderer adapters and custom story views.
local H = require("hydronium")
local M = { Context = H.createContext(nil) }
local function finite(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end
function M.validate(controls, args)
  for name, value in pairs(args) do
    local control = controls[name]
    if control then
      local kind = control.type
      if (kind == "text" or kind == "color") and type(value) ~= "string"
        or kind == "boolean" and type(value) ~= "boolean"
        or kind == "number" and not finite(value) then
        error("hydronium_lab: invalid value for control '" .. name .. "'", 2)
      end
      if kind == "number" and ((control.min and value < control.min) or (control.max and value > control.max)) then
        error("hydronium_lab: control '" .. name .. "' is outside its range", 2)
      end
      if kind == "select" then
        local found = false
        for _, option in ipairs(control.options) do
          local candidate = type(option) == "table" and option.value or option
          if candidate == value then found = true end
        end
        if not found then error("hydronium_lab: unknown option for control '" .. name .. "'", 2) end
      end
    end
  end
end
function M.new(args, controls, defaults)
  local lab = require("hydronium_lab")
  args = lab.json_value(args or {}, {}, "hydronium_lab: args")
  M.validate(controls or {}, args)
  defaults = lab.json_value(defaults or args, {}, "hydronium_lab: defaults")
  M.validate(controls or {}, defaults)
  local getArgs, writeArgs = H.signal(args)
  local playback, writePlayback = H.signal({ nowMs = 0, playing = true, frame = 0, intervalMs = 1000 / 60 })
  local state = { args = getArgs, playback = playback }
  function state.setArgs(patch)
    if type(patch) ~= "table" then error("hydronium_lab: args patch must be a table", 2) end
    patch = lab.json_value(patch, {}, "hydronium_lab: args patch")
    M.validate(controls or {}, patch)
    local nextArgs = lab.copy(getArgs())
    for key, value in pairs(patch) do nextArgs[key] = value end
    writeArgs(nextArgs)
    return nextArgs
  end
  function state.resetArgs() writeArgs(lab.copy(defaults)); return getArgs() end
  function state.setPlayback(value) writePlayback(value) end
  return state
end
local function context()
  local value = H.useContext(M.Context)
  if not value then error("hydronium_lab: story hooks require a Lab provider", 3) end
  return value
end
function M.useStoryArgs()
  local state = context()
  return state.args, state.setArgs, state.resetArgs
end
function M.usePlayback() return context().playback end
M.finite = finite
return M
