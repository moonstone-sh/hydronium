-- Perceptual color values and conversions. Public sRGB channels are bytes;
-- internal conversion stays in the 0..1 encoded sRGB domain.
local M = {}

---@class hydronium_oklab_utils.Color
---@field space "srgb"|"oklab"|"oklch"
---@field r? number sRGB byte channel, 0..255.
---@field g? number sRGB byte channel, 0..255.
---@field b? number sRGB byte channel, 0..255; also OKLab's b axis when space="oklab".
---@field l? number OKLab/OKLCH lightness.
---@field a? number OKLab a axis.
---@field c? number OKLCH chroma.
---@field h? number OKLCH hue in degrees.

local function clamp(x, lo, hi) return math.max(lo, math.min(hi, x)) end
local function finite(x, name)
  if type(x) ~= "number" or x ~= x or x == math.huge or x == -math.huge then
    error("hydronium_oklab_utils: " .. name .. " must be a finite number", 3)
  end
  return x
end
local function linear(v)
  return v <= 0.04045 and v / 12.92 or ((v + 0.055) / 1.055) ^ 2.4
end
local function encoded(v)
  return v <= 0.0031308 and 12.92 * v or 1.055 * v ^ (1 / 2.4) - 0.055
end
local function signed_cuberoot(v) return v < 0 and -(-v) ^ (1 / 3) or v ^ (1 / 3) end

function M.srgb(r, g, b)
  return { space = "srgb", r = clamp(finite(r, "r"), 0, 255), g = clamp(finite(g, "g"), 0, 255), b = clamp(finite(b, "b"), 0, 255) }
end

function M.hex(value)
  if type(value) ~= "string" then error("hydronium_oklab_utils: hex expects '#RRGGBB'", 2) end
  local r, g, b = value:match("^#(%x%x)(%x%x)(%x%x)$")
  if not r then error("hydronium_oklab_utils: hex expects opaque '#RRGGBB'", 2) end
  return M.srgb(tonumber(r, 16), tonumber(g, 16), tonumber(b, 16))
end

function M.oklab(l, a, b)
  return { space = "oklab", l = finite(l, "l"), a = finite(a, "a"), b = finite(b, "b") }
end

function M.oklch(l, c, h)
  return { space = "oklch", l = finite(l, "l"), c = math.max(0, finite(c, "c")), h = finite(h, "h") % 360 }
end

function M.to_oklab(value)
  if type(value) ~= "table" then error("hydronium_oklab_utils: expected a color value", 2) end
  if value.space == "oklab" then return M.oklab(value.l, value.a, value.b) end
  if value.space == "oklch" then
    local angle = value.h * math.pi / 180
    return M.oklab(value.l, value.c * math.cos(angle), value.c * math.sin(angle))
  end
  if value.space == "srgb" then
    local r, g, b = linear(value.r / 255), linear(value.g / 255), linear(value.b / 255)
    local l = signed_cuberoot(0.4122214708*r + 0.5363325363*g + 0.0514459929*b)
    local m = signed_cuberoot(0.2119034982*r + 0.6806995451*g + 0.1073969566*b)
    local s = signed_cuberoot(0.0883024619*r + 0.2817188376*g + 0.6299787005*b)
    return M.oklab(0.2104542553*l + 0.7936177850*m - 0.0040720468*s, 1.9779984951*l - 2.4285922050*m + 0.4505937099*s, 0.0259040371*l + 0.7827717662*m - 0.8086757660*s)
  end
  error("hydronium_oklab_utils: unknown color space '" .. tostring(value.space) .. "'", 2)
end

function M.to_oklch(value)
  local lab = M.to_oklab(value)
  local c = math.sqrt(lab.a * lab.a + lab.b * lab.b)
  return M.oklch(lab.l, c, c == 0 and 0 or math.atan2(lab.b, lab.a) * 180 / math.pi)
end

local function raw_srgb(lab)
  local l = lab.l + 0.3963377774*lab.a + 0.2158037573*lab.b
  local m = lab.l - 0.1055613458*lab.a - 0.0638541728*lab.b
  local s = lab.l - 0.0894841775*lab.a - 1.2914855480*lab.b
  l, m, s = l*l*l, m*m*m, s*s*s
  return encoded(4.0767416621*l - 3.3077115913*m + 0.2309699292*s), encoded(-1.2684380046*l + 2.6097574011*m - 0.3413193965*s), encoded(-0.0041960863*l - 0.7034186147*m + 1.7076147010*s)
end
local function in_gamut(r, g, b) return r >= 0 and r <= 1 and g >= 0 and g <= 1 and b >= 0 and b <= 1 end

function M.to_srgb(value)
  if value.space == "srgb" then return M.srgb(value.r, value.g, value.b) end
  local lch = M.to_oklch(value)
  local lab = M.to_oklab(lch)
  local r, g, b = raw_srgb(lab)
  -- Preserve lightness and hue, reducing chroma only when needed. This is
  -- vastly less surprising than blindly clipping three encoded channels.
  if not in_gamut(r, g, b) then
    local low, high = 0, lch.c
    for _ = 1, 20 do
      local mid = (low + high) / 2
      local candidate = M.to_oklab(M.oklch(lch.l, mid, lch.h))
      local cr, cg, cb = raw_srgb(candidate)
      if in_gamut(cr, cg, cb) then low = mid else high = mid end
    end
    r, g, b = raw_srgb(M.to_oklab(M.oklch(lch.l, low, lch.h)))
  end
  return M.srgb(math.floor(clamp(r, 0, 1) * 255 + 0.5), math.floor(clamp(g, 0, 1) * 255 + 0.5), math.floor(clamp(b, 0, 1) * 255 + 0.5))
end

function M.mix(a, b, amount)
  amount = clamp(finite(amount, "amount"), 0, 1)
  a, b = M.to_oklab(a), M.to_oklab(b)
  return M.oklab(a.l + (b.l-a.l)*amount, a.a + (b.a-a.a)*amount, a.b + (b.b-a.b)*amount)
end

function M.contrast(a, b)
  local function luminance(c)
    c = M.to_srgb(c)
    local r, g, bl = linear(c.r/255), linear(c.g/255), linear(c.b/255)
    return 0.2126*r + 0.7152*g + 0.0722*bl
  end
  local x, y = luminance(a), luminance(b)
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05)
end

return M
