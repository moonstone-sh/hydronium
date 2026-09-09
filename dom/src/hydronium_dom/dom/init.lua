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

--[[
  d.lua / d.js -- DOM-bound client-execution descriptors (Island/Script
  authoring surface). These are plain, immutable, callable marker tables,
  exactly like `d.button` etc. above -- `<d.lua.island>` is ordinary LUAX
  lexical tag resolution (`(d.lua).island`, then a normal call), not new
  grammar. See docs/HYDRONIUM_ISLANDS_SUSPENSE_V1.md.

  Deliberately does NOT require hydronium.interpreter.lua / .js or any
  client-runtime module: importing hydronium.dom must stay cheap even when
  islands are never used on a given page (see that doc's "tree shaking"
  section for what this enables, most of which is not implemented yet --
  only the "importing this costs nothing" half is true today).
--]]

local island_descriptor_metatable = {
  __call = function(self, props, ...)
    return elementModule.createElement(self, props, ...)
  end,
  __tostring = function(self)
    return "Hydronium.DOM.Island(" .. tostring(self.interpreter) .. ")"
  end,
  __newindex = function(_, k, _)
    error("Cannot modify immutable island descriptor property: " .. tostring(k), 2)
  end,
}

local script_descriptor_metatable = {
  __call = function(self, props, ...)
    return elementModule.createElement(self, props, ...)
  end,
  __tostring = function(self)
    return "Hydronium.DOM.Script(" .. tostring(self.interpreter) .. ")"
  end,
  __newindex = function(_, k, _)
    error("Cannot modify immutable script descriptor property: " .. tostring(k), 2)
  end,
}

--- @param interpreter "lua"|"js"
local function create_island_descriptor(interpreter)
  return setmetatable({
    ["$$typeof"] = symbols.ISLAND_DESCRIPTOR,
    _typeof = symbols.ISLAND_DESCRIPTOR,
    tag = "island",
    interpreter = interpreter,
  }, island_descriptor_metatable)
end

--- @param interpreter "js" (Lua has no equivalent script-tag concept yet)
local function create_script_descriptor(interpreter)
  return setmetatable({
    ["$$typeof"] = symbols.SCRIPT_DESCRIPTOR,
    _typeof = symbols.SCRIPT_DESCRIPTOR,
    tag = "script",
    interpreter = interpreter,
  }, script_descriptor_metatable)
end

local lua_island = create_island_descriptor("lua")
local js_island = create_island_descriptor("js")
local js_script = create_script_descriptor("js")

--- `d.lua.mount(<App/>)` is a root-sized island: the semantic equivalent
--- of `<d.lua.island root>`, so a full Lua-hydrated application and a
--- partial Lua island share the exact same client machinery (see mission
--- invariant "full application and partial islands share the same
--- hydration machinery"). Not a JSX tag -- an ordinary function call,
--- since it is always used as `return d.lua.mount(<App/>)`, not inside a
--- LUAX tag position.
--- @param vnode LuaxElement
--- @param opts? { module: string, mode: string, hydrate: string } `module`
---   is the app root component's own `require()` id -- OPTIONAL (nothing
---   breaks if omitted, matching every existing call site), but without
---   it `server/init.lua`'s `client_plan.islands` entry for this mount
---   carries no way to know which Lua module actually renders it (the
---   entry's own `raw_props.module` read is already real and unconditional
---   -- it works for `<d.lua.island module="...">` today; `lua_mount`
---   itself was the one gap, hardcoding `{root=true}` with no way to
---   pass `module` alongside it). Real, current consumer:
---   hydronium_ballad.plugins.client's M3 code-splitting, which needs a
---   Lua module id per entry point and has nowhere else to get one for a
---   root-mounted app (see docs/HYDRONIUM_CLIENT_BUNDLER_MINIFIER_PLAN.md's
---   "Hazard" and M3 sections) -- deriving it via `debug.getinfo` on the
---   component function was considered and rejected there, since
---   amalgamation changes chunknames, breaking exactly that.
local function lua_mount(vnode, opts)
  opts = opts or {}
  return elementModule.createElement(lua_island, {
    root = true,
    module = opts.module,
    mode = opts.mode,
    hydrate = opts.hydrate,
  }, vnode)
end

-- Empty outer tables with all real values behind __index: unlike a table
-- literal with pre-set keys, this ensures __newindex actually fires for
-- EVERY key (Lua only invokes __newindex for keys absent as a raw entry --
-- a literal `{island = ...}` would silently allow `t.island = other` via
-- a plain rawset, never reaching this guard).
local function namespace(entries, name)
  return setmetatable({}, {
    __index = entries,
    __newindex = function(_, k, _)
      error("Cannot modify immutable descriptor table 'd." .. name .. "'", 2)
    end,
    __tostring = function() return "Hydronium.DOM.Namespace(" .. name .. ")" end,
    __pairs = function() return pairs(entries) end,
  })
end

local dom_lua = namespace({ island = lua_island, mount = lua_mount }, "lua")
local dom_js = namespace({ island = js_island, script = js_script }, "js")

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
      if key == "lua" then
        return dom_lua
      end
      if key == "js" then
        return dom_js
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

---@type HydroniumDOMDescriptors
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
