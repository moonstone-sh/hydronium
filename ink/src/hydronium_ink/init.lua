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
             inlineViewport / focusRevision / scrollRevision / scrollDelta:
               inline-render controls; focusRevision requests revealing a
               scrollFocus=true descendant, scrollRevision applies scrollDelta.
             scrollFocus (boolean): marks the active row for inline rendering.
             overflow ("visible" | "hidden" | "scroll")
             scrollTop / scrollLeft (integer, controlled cell offsets for
               overflow="scroll"; compose with a signal and useInput)
             borderStyle ("single" draws real box-drawing characters;
               any other truthy value reserves border space but draws
               nothing -- only "single" is implemented)
             borderColor / borderTopColor / borderRightColor /
               borderBottomColor / borderLeftColor (named color, see
             Text's `color` below for accepted values) -- the per-edge props
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
    Text:    color / backgroundColor (terminal palette names, opaque
               #RRGGBB sRGB, or values from hydronium_oklab_utils)
             bold / dimColor / italic / underline / strikethrough / inverse (boolean)
             href (string, optional) -- OSC 8 hyperlink target. See "Public
               API for hyperlinks" below for why this rides on Text rather
               than a separate `<Link>` element, and
               hydronium_ink.host.terminal's "Hyperlink capability" section
               for the true/false/"auto" gate that decides whether real OSC
               8 bytes are emitted at all (default: plain, unlinked text on
               a terminal not affirmatively known to support it).
             width (integer, optional) + wrap ("truncate" |
               "truncate-start" | "truncate-middle" | "truncate-end" |
               "wrap" | "hard") -- how this Text handles content wider
               than the space it has. The truncate modes cut each line
               to fit, marking the cut with a plain ASCII "..." (not a
               Unicode ellipsis, so the marker costs the same cells on
               every terminal). `wrap` breaks at word boundaries and
               `hard` splits long words.
               `width` is optional for ALL of them: with it, the reflow
               happens up front; without it, Yoga resolves the real
               width first and the reflow runs against that. Cuts are
               grapheme-cluster aligned and measured in display cells,
               so a 2-cell character is dropped rather than split.
    Newline: no props -- a line-break marker, meaningful as a child of
             Text (forces a new line within that Text's own layout) or,
             in a reduced "occupies space, paints nothing" sense, as a
             direct child of Box.
    Spacer:  no props -- expands to consume the remaining space along
             its parent's main flex axis (a real Yoga flexGrow=1 leaf,
             see host/terminal.lua's buildYogaTree), matching real Ink's
             own Spacer exactly.
    Static:  append-only, write-once output -- React Ink's `<Static>`
             adapted to this module's plain-VNode-children idiom rather
             than its render-prop signature (there is no clean way to
             pass a per-item render FUNCTION as a child here: a bare
             function child is already a reserved calling convention
             everywhere in this framework -- core/element.lua's
             `isReactiveChildValue` -- meaning "reactive text getter,
             called with zero arguments," which a `function(item, index)`
             render prop is not). Instead: build each item's element the
             ordinary way (a plain Lua `for` loop over your own list,
             same as any other dynamic child list in this codebase, e.g.
             create/src/create/ui/checklist.lua), give each one a stable
             `key`, and pass the resulting array as Static's children --
             `H.h(ink.Static, {}, items)`. No props of its own are
             required, though the same layout props Box accepts
             (padding/flexDirection/etc) are honored identically, since
             host/terminal.lua's Yoga style mapping treats "Static"
             exactly like "Box" -- the only difference is behavioral, not
             structural: a real terminal Host (host/terminal.lua) with
             `inline` rendering renders each of Static's children EXACTLY
             ONCE, the moment it first appears among Static's children,
             writing it directly to the terminal's real, permanent
             scrollback (ABOVE the live inline region) -- never as part
             of the diffed/repainted live frame again afterwards, and
             never re-rendered even if its own props later change (an
             app that needs a "committed answer, corrected" line prints a
             NEW item, exactly like this repo's own typewriter wizard
             prototype does -- see create/src/create/ui/typewriter_app.lua).
             Append-only is a real contract, not just a naming
             convention: REMOVING or REORDERING a child that was already
             flushed has no effect on the real terminal (its bytes are
             already permanent, ordinary scrollback) and will desync this
             element's children from what is actually on screen -- only
             ever grow the list Static's children come from. Outside
             `inline` rendering (a full-screen host, or a non-terminal
             test host) Static has no special behavior at all -- it is
             indistinguishable from a plain Box, since there is no
             scrollback boundary for "write once, above the live region"
             to mean anything.
             STATED LIMITATION: a Static child using `wrap="wrap"` (or a
             truncate mode) with NO explicit `width` will not reflow
             correctly -- host/terminal.lua's flushStaticNodes lays out
             and paints each newly-appended child in one isolated pass,
             unlike host.paint()'s own live tree, which reruns
             buildYogaTree/calculateLayout a second time once Yoga's
             flex/stretch has resolved a wrap-mode Text's real available
             width (see that file's "two-pass reflow" comment). Give a
             wrapped/truncated Static child an explicit `width` (reading
             the current terminal width yourself, e.g. via
             `hooks.useWindowSize()`, works exactly as intended -- see
             this repo's own typewriter wizard prototype). This is the
             same simplification Transform's own isolated sub-render
             below already accepts, not something new to Static.
    Transform: transform(line, index) -- renders its children in
             isolation, then calls transform once per output line
             (1-indexed -- NOT real Ink's 0-indexed convention, a
             deliberate Lua-native choice) with that line's PLAIN text
             (no ANSI/style codes from its children). ANSI SGR styling in
             the transform's return value is parsed into
             terminal cells (standard 8 colors and host text styles).

  Public API for hyperlinks (OSC 8): a link is `<Text href="https://...">`,
  not a separate `<Link>`/`<A>` element the way real Ink's own ecosystem
  (`ink-link`, various user snippets) or the DOM's `<a href>` model it.
  Chosen deliberately, not by default: everywhere else in this module a
  hyperlink is exactly the same *kind* of thing as `color`/`bold`/
  `underline` -- a zero-width text-range style attribute, not a layout
  node with its own box model (it never wraps, never has padding/border,
  never participates in flex sizing on its own). `href` on Text reuses the
  exact style-inheritance machinery those props already have (see
  host/terminal.lua's textStyleOf -- a nested `<Text>` inherits its
  parent's `href` unless it sets its own, exactly like `color`), instead
  of inventing a second, parallel "wrap children in an element" mechanism
  that would need its own layout/paint branch in host/terminal.lua for a
  concept that host already treats every other run-level style as. See
  host/terminal.lua's own "OSC 8 HYPERLINK GRID REPRESENTATION" comment
  for how this decision carries all the way down to the character grid.
--]]

local symbols = require("hydronium.core.symbols")
local virtual = require("hydronium_ink.virtual")
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

---@alias HydroniumInkColor string|hydronium_oklab_utils.Color Palette name,
--- opaque #RRGGBB, or an sRGB/OKLab/OKLCH value from hydronium/oklab-utils.

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
---@field scrollTop? integer Controlled vertical offset in terminal cells.
---@field scrollLeft? integer Controlled horizontal offset in terminal cells.
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
---@field href? string OSC 8 hyperlink target for this run of text. Inherited by
--- nested Text the same way `color` is (a nested `href` overrides; `href = ""`
--- explicitly clears an inherited one). Degrades to plain, unlinked text when
--- the terminal isn't known to support OSC 8 -- see
--- hydronium_ink.host.terminal's "Hyperlink capability" section and
--- hydronium_ink.session's `hyperlinks` option.
---@field width? integer
---@field wrap? "truncate"|"truncate-start"|"truncate-middle"|"truncate-end"|"wrap"|"hard"

---@class HydroniumInkTransformProps
---@field transform fun(line: string, index: integer): string

---@class HydroniumInkStaticProps : HydroniumInkBoxProps
--- No fields of its own -- see hydronium_ink/init.lua's own "Static:" doc
--- comment above (the array of children IS the append-only item list;
--- give each one a stable `key`). Accepts the same layout props as Box.

---@class HydroniumInkDescriptors
---@field Box hydronium.Intrinsic<HydroniumInkBoxProps, "terminal"> | fun(props?: HydroniumInkBoxProps, ...: any): LuaxElement
---@field Text hydronium.Intrinsic<HydroniumInkTextProps, "terminal"> | fun(props?: HydroniumInkTextProps, ...: any): LuaxElement
---@field Newline hydronium.Intrinsic<{}, "terminal"> | fun(props?: {}, ...: any): LuaxElement
---@field Spacer hydronium.Intrinsic<{}, "terminal"> | fun(props?: {}, ...: any): LuaxElement
---@field Transform hydronium.Intrinsic<HydroniumInkTransformProps, "terminal"> | fun(props?: HydroniumInkTransformProps, ...: any): LuaxElement
---@field Static hydronium.Intrinsic<HydroniumInkStaticProps, "terminal"> | fun(props?: HydroniumInkStaticProps, ...: any): LuaxElement
---@field createIntrinsic fun(tag: string): hydronium.Intrinsic<any, "terminal">
---@field terminal_background fun(opts?: table): hydronium_oklab_utils.Color|nil, string|nil Detects the real terminal background via OSC 11 (falling back to `COLORFGBG`, then `nil`). See hydronium_ink.terminal_background's own doc comment -- call this ONCE, at startup, before a session's normal input loop starts.
---@field colorProfile fun(value?: "auto"|"truecolor"|"ansi256"|"ansi16"|"none"): "truecolor"|"ansi256"|"ansi16"|"none" Plain (non-reactive, non-hook) equivalent of `hydronium_ink.hooks.useColorProfile()`, for code that runs outside a mounted component tree -- CLI startup, a plain module scanning `os.getenv` itself, a story file choosing what to show before any session exists. Same NO_COLOR/FORCE_COLOR-honoring "auto" detection (see hydronium_ink.color.profile); an explicit `value` bypasses detection entirely.
---@field byProfile fun(entries: table<"truecolor"|"ansi256"|"ansi16"|"none", any>): hydronium_ink.ByProfile Marks a single Text/Box prop value (a color, or a structural style prop like `inverse`/`bold`/`dimColor`) as resolved per the CURRENT color profile rather than fixed -- see hydronium_ink.color.by_profile's own doc comment for the full fallback-chain contract. `ink.adaptive` below is the exact same function under a name that reads better on a color specifically.
---@field adaptive fun(entries: table<"truecolor"|"ansi256"|"ansi16"|"none", any>): hydronium_ink.ByProfile Alias of `ink.byProfile`, e.g. `color = ink.adaptive({ truecolor = oklch(0.75, 0.1, 221), ansi16 = "cyan" })`.

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
  Static = create_descriptor("Static"),
  createIntrinsic = create_descriptor,
  createVirtualHost = virtual.createVirtualHost,
  terminal_background = require("hydronium_ink.terminal_background").detect,
  colorProfile = require("hydronium_ink.color").profile,
  byProfile = require("hydronium_ink.color").by_profile,
  adaptive = require("hydronium_ink.color").by_profile,
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
