--[[
  Hydronium Ink Terminal Intrinsic Descriptor Module (`require("hydronium_ink")`)
  Mirrors dom/src/hydronium_dom/dom/init.lua's exact descriptor pattern
  (immutable, callable, $$typeof = symbols.INTRINSIC tables carrying a bare
  string `tag`) for a small set of terminal-UI primitives modeled on React
  Ink's Box/Text/Newline. Tagged host = "terminal" so
  hydronium_ink.host.terminal's createInstance always receives a plain tag
  string ("Box" | "Text" | "Newline") -- exactly the same unwrapping
  hydronium_dom relies on for "button"/"div"/etc, via
  core/src/hydronium/core/element.lua's createElement and
  core/src/hydronium/core/reconciler.lua's unwrapTag.

  LuaJIT-only (not the wider Lua 5.1-5.4 compatibility the rest of this
  repo's modules maintain): the terminal Host adapter's layout is backed by
  a real Yoga flexbox engine via LuaJIT's `ffi`, which has no equivalent in
  plain PUC Lua. Packages/naming are scoped by ABI, not interpreter -- see
  ink/moonstone.toml -- so a real PUC-Lua-5.1 sibling (a compiled C module
  instead of FFI) could join later without a rename.

  Supported props (see docs/HYDRONIUM_INK_TERMINAL_HOST.md for the full,
  honest scope statement of what each one does and does not do):

    Box:     flexDirection ("row" | "column", default "column")
             justifyContent ("flex-start" | "center" | "flex-end" |
               "space-between" | "space-around" | "space-evenly")
             alignItems ("auto" | "flex-start" | "center" | "flex-end" |
               "stretch" | "baseline" | "space-between" | "space-around" |
               "space-evenly")
             flexWrap ("nowrap" | "wrap" | "wrap-reverse")
             flexGrow / flexShrink (number)
             flexBasis (number | "auto")
             padding / paddingX / paddingY (integer, spaces)
             margin / marginX / marginY (integer, spaces)
             position ("relative" | "absolute"), top / right / bottom / left (integer)
             display ("flex" | "none")
             overflow ("visible" | "hidden" | "scroll" -- "scroll" is
               treated identically to "hidden": clips, but there is no
               real scrollable viewport)
             borderStyle ("single" draws real box-drawing characters;
               any other truthy value reserves border space but draws
               nothing -- only "single" is implemented)
             borderColor / borderTopColor / borderRightColor /
               borderBottomColor / borderLeftColor (named color, see
               Text's `color` below for the set) -- the per-edge props
               override `borderColor` on that edge only; corners use
               `borderColor` directly, not either adjacent edge (a
               stated simplification, see host/terminal.lua's
               resolveBorderEdge)
             borderDimColor / borderTopDimColor / ... (boolean, same
               per-edge override pattern as the color props)
             backgroundColor (named color, fills the box's own full
               rect -- border chars are drawn on top of it, so a
               bordered box's interior AND its border cells share the
               same background)
             width / height (integer, optional -- overrides auto-sizing)
             All of the above are real Yoga flexbox properties (see
             hydronium_ink.yoga_ffi) -- grow/shrink/wrap/justify/align
             actually work, unlike the block-stacking layout this replaced.
    Text:    color / backgroundColor (one of: red, green, yellow, blue,
               magenta, cyan, white, gray -- see host/terminal.lua's
               COLOR_CODES)
             bold / dimColor / italic / underline / strikethrough / inverse (boolean)
             width (integer, optional) + wrap ("truncate" |
               "truncate-start" | "truncate-middle" | "truncate-end") --
               truncates (with a plain ASCII "..." marker, not a real
               Unicode ellipsis -- this module has no wide-character
               width accounting anywhere yet) to fit `width` when both
               are set. `wrap = "wrap"`/`"hard"` (real reflow) is
               explicitly NOT implemented -- see
               docs/HYDRONIUM_INK_TERMINAL_HOST.md for why (it needs a
               Yoga measure-function callback this binding doesn't
               register, not just a truncation pass).
    Newline: no props -- a line-break marker, meaningful as a child of
             Text (forces a new line within that Text's own layout) or,
             in a reduced "occupies space, paints nothing" sense, as a
             direct child of Box.
    Spacer:  no props -- expands to consume the remaining space along
             its parent's main flex axis (a real Yoga flexGrow=1 leaf,
             see host/terminal.lua's buildYogaTree), matching real Ink's
             own Spacer exactly.
    Transform: transform(line, index) -- renders its children in
             isolation, then calls transform once per output line
             (1-indexed -- NOT real Ink's 0-indexed convention, a
             deliberate Lua-native choice) with that line's PLAIN text
             (no ANSI/style codes -- see host/terminal.lua's own doc
             comment on Transform for why: a transform that itself
             injects ANSI codes, e.g. a real gradient/chalk library,
             is not supported here, since that would need this module to
             parse ANSI back out of the transform's own return value
             into real cell styles, which it does not attempt). The
             transform's return value is painted as plain unstyled text.
--]]

local symbols = require("hydronium.core.symbols")
local elementModule = require("hydronium.core.element")

local descriptor_metatable = {
  __call = function(self, props, ...)
    return elementModule.createElement(self, props, ...)
  end,
  __tostring = function(self)
    return "Hydronium.Ink.Intrinsic(" .. (self.tag or "intrinsic") .. ")"
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
    host = "terminal",
  }
  return setmetatable(desc, descriptor_metatable)
end

--- Tier-1 hand-authored LuaCATS catalog (see
--- docs/LUAX_HOST_TYPE_AUTHORING.md): reuses `hydronium.Intrinsic<P, H>`
--- from luax/types/luax.d.lua completely unmodified -- the same generic
--- type `dom/types/dom/init.d.lua` uses for `d.button` etc., proving it
--- was already host-agnostic. Annotated inline on this real module
--- (not a separate ambient `.d.lua` file) since this catalog is small
--- and hand-written, unlike DOM's spec-generated one -- see that doc for
--- when a host's catalog is big/spec-driven enough to warrant the
--- ambient-file (Tier 2) approach instead.

---@alias HydroniumInkColor "red"|"green"|"yellow"|"blue"|"magenta"|"cyan"|"white"|"gray"

---@class HydroniumInkBoxProps
---@field flexDirection? "row"|"column"
---@field justifyContent? "flex-start"|"center"|"flex-end"|"space-between"|"space-around"|"space-evenly"
---@field alignItems? "auto"|"flex-start"|"center"|"flex-end"|"stretch"|"baseline"|"space-between"|"space-around"|"space-evenly"
---@field flexWrap? "nowrap"|"wrap"|"wrap-reverse"
---@field flexGrow? number
---@field flexShrink? number
---@field flexBasis? number|"auto"
---@field padding? integer
---@field paddingX? integer
---@field paddingY? integer
---@field margin? integer
---@field marginX? integer
---@field marginY? integer
---@field position? "relative"|"absolute"
---@field top? integer
---@field right? integer
---@field bottom? integer
---@field left? integer
---@field display? "flex"|"none"
---@field overflow? "visible"|"hidden"|"scroll"
---@field borderStyle? "single"|boolean
---@field borderColor? HydroniumInkColor
---@field borderTopColor? HydroniumInkColor
---@field borderRightColor? HydroniumInkColor
---@field borderBottomColor? HydroniumInkColor
---@field borderLeftColor? HydroniumInkColor
---@field borderDimColor? boolean
---@field borderTopDimColor? boolean
---@field borderRightDimColor? boolean
---@field borderBottomDimColor? boolean
---@field borderLeftDimColor? boolean
---@field backgroundColor? HydroniumInkColor
---@field width? integer
---@field height? integer

---@class HydroniumInkTextProps
---@field color? HydroniumInkColor
---@field backgroundColor? HydroniumInkColor
---@field bold? boolean
---@field dimColor? boolean
---@field italic? boolean
---@field underline? boolean
---@field strikethrough? boolean
---@field inverse? boolean
---@field width? integer
---@field wrap? "truncate"|"truncate-start"|"truncate-middle"|"truncate-end"

---@class HydroniumInkTransformProps
---@field transform fun(line: string, index: integer): string

---@class HydroniumInkDescriptors
---@field Box hydronium.Intrinsic<HydroniumInkBoxProps, "terminal"> | fun(props?: HydroniumInkBoxProps, ...: any): LuaxElement
---@field Text hydronium.Intrinsic<HydroniumInkTextProps, "terminal"> | fun(props?: HydroniumInkTextProps, ...: any): LuaxElement
---@field Newline hydronium.Intrinsic<{}, "terminal"> | fun(props?: {}, ...: any): LuaxElement
---@field Spacer hydronium.Intrinsic<{}, "terminal"> | fun(props?: {}, ...: any): LuaxElement
---@field Transform hydronium.Intrinsic<HydroniumInkTransformProps, "terminal"> | fun(props?: HydroniumInkTransformProps, ...: any): LuaxElement
---@field createIntrinsic fun(tag: string): hydronium.Intrinsic<any, "terminal">

---@type HydroniumInkDescriptors
local ink = {
  Box = create_descriptor("Box"),
  Text = create_descriptor("Text"),
  Newline = create_descriptor("Newline"),
  -- No props, matching real Ink -- host/terminal.lua's buildYogaTree
  -- gives this tag a default flexGrow=1 (a Spacer's whole purpose is to
  -- consume the remaining space along its parent's main flex axis).
  Spacer = create_descriptor("Spacer"),
  Transform = create_descriptor("Transform"),
  createIntrinsic = create_descriptor,
}

setmetatable(ink, {
  __newindex = function(_, k, _)
    error("Cannot modify immutable hydronium.ink module", 2)
  end,
  __tostring = function(_)
    return "Hydronium.Ink.Descriptors"
  end,
})

return ink
