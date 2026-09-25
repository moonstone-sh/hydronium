-- JSON-safe projection of Ink's canonical frame. This reads styled cells;
-- ANSI encoding belongs only to the native terminal adapter.
local M = {}
local terminalColor = require("hydronium_ink.color")

local function color(value, capability)
  value = terminalColor.lower(value, capability)
  if value == nil then return nil end
  if value.kind == "palette" or value.kind == "index" then
    return { kind = value.kind, index = value.index }
  end
  return { kind = "rgb", r = value.r, g = value.g, b = value.b }
end

local function cell(value, capability)
  return {
    ch = value.ch,
    fg = color(value.fg, capability),
    bg = color(value.bg, capability),
    bold = value.bold or false,
    dim = value.dim or false,
    italic = value.italic or false,
    underline = value.underline or false,
    strikethrough = value.strikethrough or false,
    inverse = value.inverse or false,
  }
end

function M.from_session(session)
  local frame = session:frame()
  if not frame then error("hydronium_ink_lab.snapshot: session has no painted frame", 2) end
  local capability = session:colorCapability()
  local rows = {}
  for y = 1, frame.h do
    local row = {}
    for x = 1, frame.w do row[x] = cell(frame.rows[y][x], capability) end
    rows[y] = row
  end
  return {
    version = 1,
    width = frame.w,
    height = frame.h,
    color = capability,
    -- Independent of `color` above (see hydronium_ink.color's own doc
    -- comment): the color PROFILE (adds "none"), reflecting whatever the
    -- most recent `op = "colorProfile"` request (or the story's own
    -- default) actually resolved to -- so a client can confirm/display
    -- which profile is live after switching it.
    colorProfile = session:colorProfile(),
    rows = rows,
    cursor = session:cursor(),
    status = session:status(),
  }
end

return M
