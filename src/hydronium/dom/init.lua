--[[
  Hydronium DOM Intrinsic Descriptor Module
  Provides lexical `d` and `dom` namespaces where tags (e.g. `d.button`, `d.input`)
  are immutable runtime descriptor tables with $$typeof = symbols.INTRINSIC,
  tag = "<tag>", host = "dom", and callable metamethod __call that delegates to createElement.
  Compatible with Lua 5.1, 5.2, 5.3, 5.4, and LuaJIT.
--]]

local symbols = require("hydronium.core.symbols")
local elementModule = require("hydronium.core.element")

local descriptor_metatable = {
  __call = function(self, props, ...)
    return elementModule.createElement(self, props, ...)
  end,
  __tostring = function(self)
    return "Hydronium.DOM.Intrinsic(" .. (self.tag or "intrinsic") .. ")"
  end,
  __eq = function(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    local a_typeof = a["$$typeof"] or a._typeof
    local b_typeof = b["$$typeof"] or b._typeof
    return a_typeof == symbols.INTRINSIC and b_typeof == symbols.INTRINSIC and a.tag == b.tag and a.host == b.host
  end,
  __newindex = function(_, k, _)
    error("Cannot modify immutable intrinsic descriptor property: " .. tostring(k), 2)
  end,
}

local function create_descriptor(tag_name)
  local desc = {
    ["$$typeof"] = symbols.INTRINSIC,
    _typeof = symbols.INTRINSIC,
    tag = tag_name,
    host = "dom",
  }
  return setmetatable(desc, descriptor_metatable)
end

local STANDARD_TAGS = {
  -- HTML tags
  "a", "abbr", "address", "area", "article", "aside", "audio", "b", "base",
  "bdi", "bdo", "blockquote", "body", "br", "button", "canvas", "caption",
  "cite", "code", "col", "colgroup", "data", "datalist", "dd", "del",
  "details", "dfn", "dialog", "div", "dl", "dt", "em", "embed", "fieldset",
  "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6",
  "head", "header", "hgroup", "hr", "html", "i", "iframe", "img", "input",
  "ins", "kbd", "label", "legend", "li", "link", "main", "map", "mark",
  "menu", "meta", "meter", "nav", "noscript", "object", "ol", "optgroup",
  "option", "output", "p", "picture", "pre", "progress", "q", "rp", "rt",
  "ruby", "s", "samp", "script", "search", "section", "select", "slot",
  "small", "source", "span", "strong", "style", "sub", "summary", "sup",
  "table", "tbody", "td", "template", "textarea", "tfoot", "th", "thead",
  "time", "title", "tr", "track", "u", "ul", "var", "video", "wbr",
  -- SVG tags
  "svg", "path", "circle", "rect", "line", "polyline", "polygon", "g",
  "text", "tspan", "defs", "use", "symbol", "clipPath", "mask", "pattern",
  "linearGradient", "radialGradient", "stop", "image"
}

local cache = {}
for _, tag in ipairs(STANDARD_TAGS) do
  cache[tag] = create_descriptor(tag)
end

local d = {}

local d_mt = {
  __index = function(t, key)
    if type(key) == "string" then
      if key == "d" then
        return d
      end
      if not cache[key] then
        cache[key] = create_descriptor(key)
      end
      return cache[key]
    end
    return nil
  end,
  __newindex = function(_, k, _)
    error("Cannot modify immutable descriptor table 'd'", 2)
  end,
  __pairs = function(_)
    return pairs(cache)
  end,
  __tostring = function(_)
    return "Hydronium.DOM.Descriptors(d)"
  end,
}

setmetatable(d, d_mt)

local dom = {
  d = d,
  createIntrinsic = create_descriptor,
}

setmetatable(dom, {
  __index = function(_, key)
    if key == "d" then return d end
    if key == "createIntrinsic" then return create_descriptor end
    return d[key]
  end,
  __newindex = function(_, k, _)
    error("Cannot modify immutable hydronium.dom module", 2)
  end,
  __pairs = function(_)
    return pairs(cache)
  end,
})

return dom
