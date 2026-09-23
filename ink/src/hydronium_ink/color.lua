-- Terminal-color boundary. Palette names deliberately remain palette
-- references; absolute sRGB/OKLCH values are lowered only at paint time.
local oklab = require("hydronium_oklab_utils")

local M = {}

local PALETTE = {
  black = 0, red = 1, green = 2, yellow = 3, blue = 4, magenta = 5, cyan = 6, white = 7,
  brightBlack = 8, brightRed = 9, brightGreen = 10, brightYellow = 11,
  brightBlue = 12, brightMagenta = 13, brightCyan = 14, brightWhite = 15,
}
local ANSI16_RGB = {
  { 0, 0, 0 }, { 205, 49, 49 }, { 13, 188, 121 }, { 229, 229, 16 },
  { 36, 114, 200 }, { 188, 63, 188 }, { 17, 168, 205 }, { 229, 229, 229 },
  { 102, 102, 102 }, { 241, 76, 76 }, { 35, 209, 139 }, { 245, 245, 67 },
  { 59, 142, 234 }, { 214, 112, 214 }, { 41, 184, 219 }, { 255, 255, 255 },
}

local function clamp(x, low, high) return math.max(low, math.min(high, x)) end
local function term_capability(value)
  if value == "truecolor" or value == "ansi256" or value == "ansi16" then return value end
  if value ~= nil and value ~= "auto" then error("hydronium_ink.color: unsupported capability '" .. tostring(value) .. "'", 3) end
  local colorterm = (os.getenv("COLORTERM") or ""):lower()
  if colorterm:find("truecolor", 1, true) or colorterm:find("24bit", 1, true) then return "truecolor" end
  if (os.getenv("TERM") or ""):find("256color", 1, true) then return "ansi256" end
  return "ansi16"
end
M.capability = term_capability

function M.resolve(value)
  if value == nil or value == "default" then return nil end
  if type(value) == "string" then
    if PALETTE[value] ~= nil then return { kind = "palette", index = PALETTE[value] } end
    if value:match("^#%x%x%x%x%x%x$") then
      local rgb = oklab.hex(value)
      return { kind = "rgb", r = rgb.r, g = rgb.g, b = rgb.b }
    end
    error("hydronium_ink.color: unknown palette color or invalid hex '" .. value .. "'", 3)
  end
  if type(value) == "table" and (value.space == "srgb" or value.space == "oklab" or value.space == "oklch") then
    local rgb = oklab.to_srgb(value)
    return { kind = "rgb", r = rgb.r, g = rgb.g, b = rgb.b }
  end
  error("hydronium_ink.color: color must be a palette name, '#RRGGBB', or hydronium_oklab_utils value", 3)
end

function M.key(color)
  if not color then return "default" end
  if color.kind == "palette" then return "p" .. color.index end
  if color.kind == "index" then return "i" .. color.index end
  return "r" .. color.r .. ":" .. color.g .. ":" .. color.b
end

local function xterm256_rgb(index)
  if index < 16 then return ANSI16_RGB[index + 1] end
  if index >= 232 then
    local gray = 8 + (index - 232) * 10
    return { gray, gray, gray }
  end
  local n = index - 16
  local r, g, b = math.floor(n / 36), math.floor(n / 6) % 6, n % 6
  local levels = { 0, 95, 135, 175, 215, 255 }
  return { levels[r + 1], levels[g + 1], levels[b + 1] }
end

local function distance(a, b)
  local dr, dg, db = a.r - b[1], a.g - b[2], a.b - b[3]
  return dr*dr + dg*dg + db*db
end
local function nearest16(rgb)
  local best, bestDistance = 0, math.huge
  for i, candidate in ipairs(ANSI16_RGB) do
    local d = distance(rgb, candidate)
    if d < bestDistance then best, bestDistance = i - 1, d end
  end
  return best
end
local function nearest256(rgb)
  local best, bestDistance = 16, math.huge
  for i = 16, 255 do
    local d = distance(rgb, xterm256_rgb(i))
    if d < bestDistance then best, bestDistance = i, d end
  end
  return best
end

--- Projects a canonical color onto a terminal capability without encoding it
--- as ANSI. Browser frame consumers use this to preview the same gamut the
--- native terminal encoder would produce.
function M.lower(color, capability)
  if color == nil or color.kind == "palette" then return color end
  capability = term_capability(capability)
  if color.kind == "index" then
    if capability == "ansi16" then
      local rgb = xterm256_rgb(color.index)
      return { kind = "palette", index = nearest16({ r = rgb[1], g = rgb[2], b = rgb[3] }) }
    end
    return color
  end
  if capability == "ansi16" then return { kind = "palette", index = nearest16(color) } end
  if capability == "ansi256" then return { kind = "index", index = nearest256(color) } end
  return color
end

function M.sgr(color, background, capability)
  if not color then return "" end
  capability = term_capability(capability)
  local prefix = background and 48 or 38
  if color.kind == "palette" then
    if color.index < 8 then return "\27[" .. (background and 40 or 30) + color.index .. "m" end
    return "\27[" .. (background and 100 or 90) + color.index - 8 .. "m"
  end
  if color.kind == "index" then
    if capability == "ansi256" or capability == "truecolor" then return "\27[" .. prefix .. ";5;" .. color.index .. "m" end
    local r = xterm256_rgb(color.index)
    return M.sgr({ kind = "palette", index = nearest16({ r = r[1], g = r[2], b = r[3] }) }, background, capability)
  end
  if capability == "truecolor" then return "\27[" .. prefix .. ";2;" .. color.r .. ";" .. color.g .. ";" .. color.b .. "m" end
  if capability == "ansi256" then return "\27[" .. prefix .. ";5;" .. nearest256(color) .. "m" end
  return M.sgr({ kind = "palette", index = nearest16(color) }, background, capability)
end

function M.from_sgr(params, currentFg, currentBg)
  local values = {}
  for n in tostring(params):gmatch("%d+") do values[#values + 1] = tonumber(n) end
  local fg, bg = currentFg, currentBg
  local style = {}
  local i = 1
  while i <= #values do
    local n = values[i]
    if n == 0 then fg, bg, style = nil, nil, {}
    elseif n == 1 then style.bold = true elseif n == 2 then style.dim = true elseif n == 3 then style.italic = true
    elseif n == 4 then style.underline = true elseif n == 7 then style.inverse = true elseif n == 9 then style.strikethrough = true
    elseif n == 22 then style.bold, style.dim = false, false elseif n == 23 then style.italic = false elseif n == 24 then style.underline = false
    elseif n == 27 then style.inverse = false elseif n == 29 then style.strikethrough = false
    elseif n >= 30 and n <= 37 then fg = { kind = "palette", index = n - 30 } elseif n >= 90 and n <= 97 then fg = { kind = "palette", index = n - 90 + 8 }
    elseif n == 39 then fg = nil elseif n >= 40 and n <= 47 then bg = { kind = "palette", index = n - 40 } elseif n >= 100 and n <= 107 then bg = { kind = "palette", index = n - 100 + 8 } elseif n == 49 then bg = nil
    elseif (n == 38 or n == 48) and values[i + 1] == 5 and values[i + 2] then
      if n == 38 then fg = { kind = "index", index = clamp(values[i + 2], 0, 255) } else bg = { kind = "index", index = clamp(values[i + 2], 0, 255) } end
      i = i + 2
    elseif (n == 38 or n == 48) and values[i + 1] == 2 and values[i + 4] then
      local color = { kind = "rgb", r = clamp(values[i + 2], 0, 255), g = clamp(values[i + 3], 0, 255), b = clamp(values[i + 4], 0, 255) }
      if n == 38 then fg = color else bg = color end
      i = i + 4
    end
    i = i + 1
  end
  return fg, bg, style
end

M.palette = PALETTE
return M
