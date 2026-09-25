--[[
  hydronium.host.terminal -- "Hydronium Ink", a real terminal-rendering
  Host adapter for `hydronium.core.reconciler`, analogous to React Ink.

  Implements exactly the 7-method Host contract the general Reconciler
  drives for a plain mount/update/unmount cycle (see core/reconciler.lua's
  :mount/:reconcile/:unmount and core/src/hydronium/test/host.lua's TestHost,
  the simplest real reference implementation of that same contract):

    createInstance(tag, props) -> hostNode
    createTextInstance(text) -> hostNode
    appendChild(parent, child)
    insertBefore(parent, child, beforeChild)
    removeChild(parent, child)
    commitUpdate(hostNode, oldProps, newProps)
    commitTextUpdate(hostNode, oldText, newText)

  The Reconciler always calls these as PLAIN function calls (never
  `host:method(...)`), e.g. `self.host.createInstance(unwrapTag(vnode.tag),
  vnode.props)` -- see core/reconciler.lua lines around :mount(). This
  module follows dom/src/hydronium_dom/host/dom.lua's convention of plain
  functions, not TestHost's defensive self-or-first-arg disambiguation (TestHost
  needs that only because it is also driven directly, `:`-style, by some
  of its own callers in tests -- this module is not).

  Host node representation (own internal data, not a real OS resource --
  see the mission brief's explicit note that this is fine, unlike a real
  DOM element): plain Lua tables of shape
    { type = "root" | "element" | "text", tag = <string>, props = {...},
      text = <string>, children = {...}, parent = <node|nil> }
  `root` is this host's own synthetic container node (like TestHost's
  `root`), fetched via host.getRoot() -- not part of the 7-method
  contract, but the same "extra convenience method beyond the required
  contract" pattern host/dom.lua uses for hydrateProps/mismatchLog etc.

  REPAINT STRATEGY (read this before assuming more than what's here):
  every mutating host call (appendChild/insertBefore/removeChild/
  commitUpdate/commitTextUpdate) only marks the tree dirty; the actual
  diff+paint+write only happens when something calls host.flush()
  explicitly. This was NOT the first design tried -- see
  docs/HYDRONIUM_INK_TERMINAL_HOST.md's "Repaint strategy" section for
  the real, captured-on-a-real-pty evidence of why: painting
  SYNCHRONOUSLY on every individual mutating call (the naive "always
  correct, never stale" choice) turned out to genuinely corrupt the
  visible output during an ordinary re-render, because
  core/reconciler.lua's own reconcileChildren() unconditionally
  re-appends every child "to ensure sibling order" even when the order
  didn't change -- each single appendChild() in that loop, painted
  eagerly, is a real, briefly-wrong-order intermediate frame, and a
  synchronous-per-call host flushes every one of those to the real
  terminal. This Host contract, as specified, exposes no end-of-commit
  hook to batch against without modifying core/reconciler.lua (out of
  scope for this module -- see the mission brief), so instead of
  guessing at a commit boundary, the boundary is made an explicit part
  of this host's own (beyond-the-7-method-contract) API: callers flush
  after reconciler:mount()/:reconcile() returns, or after
  scheduler.flush() returns (see tests/host/terminal_spec.lua and
  examples/ink_demo/run.lua for both). Forgetting to call flush() means
  nothing new is ever painted -- a real, documented sharp edge, not a
  silent failure mode this module tries to hide.

  DIFFING: each paint diffs the freshly computed character+style grid
  against the grid from the previous paint (cell-by-cell, coalesced into
  contiguous same-row runs) and emits ANSI cursor moves + characters only
  for the cells that actually changed -- real diffing, not a
  full-repaint-per-commit stand-in, EXCEPT on the very first paint or
  whenever the frame's overall width/height changes, when a full
  clear+redraw is used (there is no previous frame of the same shape to
  diff against). See docs/HYDRONIUM_INK_TERMINAL_HOST.md.

  LAYOUT: real flexbox, via the actual upstream facebook/yoga engine
  (`hydronium_ink.yoga_ffi`, a LuaJIT FFI binding to Yoga's real C API --
  see that file's own doc comment for why no existing "Lua Yoga binding"
  was trustworthy enough to use instead). `Box` supports flexDirection,
  justifyContent, alignItems, flexWrap, flexGrow, flexShrink, flexBasis,
  padding[X/Y], border, width/height -- real grow/shrink/wrap/justify/align
  now work, which the block-stacker this replaced never could. Each host
  node keeps ONE real, persistent Yoga node alive across paints (created
  once, patched in place via node._styleDirty/_childrenDirty from then
  on, freed only when host.removeChild() really removes it -- see this
  file's own "Incremental Yoga sync" section and buildYogaTree()'s doc
  comment), NOT rebuilt from scratch every paint() the way it used to be.
  A paint containing a `wrap="wrap"`/`"hard"` Text with no explicit width
  still resyncs the WHOLE tree twice (see host.paint()'s own doc comment
  on the two-pass reflow this needs) -- but "resync," under persistence,
  means "patch whatever's dirty," not "recreate everything," so this
  costs far less than it did before persistence landed. Text measurement
  (collectTextLines et al.) stays this module's own responsibility,
  feeding Yoga fixed-size leaves for everything except that one
  no-explicit-width reflow case, which needs Yoga's own flex/stretch to
  resolve a width first. The root is terminal-size-constrained when
  host.setSize() has been called (render.lua does, from the real terminal
  size), auto-sized to content otherwise. All text measurement/painting
  goes through hydronium_ink.text_metrics for real Unicode display width
  and grapheme-cluster segmentation, not byte
  count. See docs/HYDRONIUM_INK_TERMINAL_HOST.md.

  FIXED SCALING COST (was "KNOWN REMAINING", discovered profiling the
  persistence work above rather than assumed, fixed 2026-09-23): the OLD
  detachFromParent's `table.remove(siblings, i)` was O(remaining
  siblings), and core/reconciler.lua's own reconcileChildren calls
  appendChild for EVERY child on EVERY re-render "to ensure sibling order"
  (see this file's own "REPAINT STRATEGY" doc comment above) even when the
  order didn't change -- so a Box with N children re-rendered in O(N^2),
  dominated by table.remove, not by anything Yoga-related. Sampling
  profiler evidence at the time: for N=2000 siblings with one child's text
  changing, table.remove accounted for over half of all samples taken
  during a single update, and the persistent-Yoga-tree work above measured
  as functionally free by comparison (calculateLayout over 2000
  already-built nodes: ~1 microsecond; the OLD full-rebuild code's 2000
  newNode+free calls: ~1.5ms -- both dwarfed by table.remove's cost at
  this N).

  The fix, exactly as anticipated here at the time: `parent.children`
  stopped being a plain shifting array as the ground truth for mutation.
  See this file's own "Sibling list" section (right before
  detachFromParent below) for the real structure (an intrusive
  doubly-linked list) and childrenArray()'s own doc comment for how every
  OTHER function in this file that walks `.children` by index keeps
  working completely unchanged -- the ripple this comment used to warn
  about turned out to be containable to childrenArray() itself, not
  something that touched every call site's own logic. Measured
  before/after with a real benchmark (see the "O(N) re-render" describe
  block in tests/host/terminal_spec.lua for the exact numbers this session
  captured): re-rendering a single changed child among N siblings went
  from scaling quadratically with N to scaling roughly linearly.

  LuaJIT-only: see hydronium_ink/init.lua's doc comment for why (Yoga is
  bound via LuaJIT's `ffi`, which plain PUC Lua has no equivalent of).
--]]

local Yoga = require("hydronium_ink.yoga_ffi")
local textMetrics = require("hydronium_ink.text_metrics")
local terminalColor = require("hydronium_ink.color")

local M = {}

-- The color PROFILE (see hydronium_ink.color's own doc comment for how this
-- differs from `_colorCapability`/`terminalColor.capability`) in effect for
-- the paint pass currently running. A module-level upvalue rather than a
-- parameter threaded through buildYogaTree/textStyleOf/paintNode/
-- resolveBorderEdge/collectTextLines (all plain module-level functions
-- below, not methods on `host`, exactly like `REFLOW_MODES`/`BOX_CHARS`
-- further down are shared via upvalue rather than an argument every one of
-- them would otherwise need to accept and pass along): host.paint() sets
-- this once, right before its measure+paint passes, and every prop
-- resolved during that SAME paint() call sees the same value -- there is
-- no concurrent paint() call this could race with (session.lua drives
-- everything from one single-threaded event loop).
local currentColorProfile = "truecolor"

--- Resolves a single Text/Box prop value that may be a
--- `hydronium_ink.color.by_profile(...)` marker (`ink.byProfile`/
--- `ink.adaptive`) against `currentColorProfile`. Returns `value, true` for
--- an ordinary (non-marker) value unchanged -- so a plain
--- `color = "#rrggbb"` or `bold = true` prop takes this exact same path as
--- always and behaves identically regardless of color profile, which is
--- this package's stated default: adaptive behavior is opt-in per prop,
--- never implicit.
---
--- `isColor` selects which of `hydronium_ink.color`'s two resolvers backs
--- this: pass `true` for `color`/`backgroundColor`/`borderColor`/border
--- edge colors (`M.resolve_by_profile_color`, whose "none" case actively
--- strips to `nil` rather than inheriting a richer profile's real color);
--- leave it false/nil for structural props (`bold`/`dimColor`/`inverse`/
--- etc., `M.resolve_by_profile`, which has no such special case -- a
--- boolean has no quantization step to opt out of). `present = false`
--- means "no override applies for this profile" (see
--- `hydronium_ink.color.resolve_by_profile`'s own doc comment) -- the
--- caller must leave whatever it already had (an inherited style, or
--- simply not setting this field at all) rather than overwriting it with
--- `nil`/false.
--- @param value any
--- @param isColor? boolean
--- @return any resolved, boolean present
local function resolveStyleValue(value, isColor)
  if terminalColor.is_by_profile(value) then
    if isColor then
      return terminalColor.resolve_by_profile_color(value, currentColorProfile)
    end
    return terminalColor.resolve_by_profile(value, currentColorProfile)
  end
  return value, true
end

-- Palette names lower to their terminal SGR slots, preserving the user's
-- active terminal theme. Absolute #RRGGBB/OKLab colors are represented by
-- terminalColor objects and lowered only when the frame is encoded.
local COLOR_CODES = terminalColor.palette

-- Only "single" is implemented. Any other truthy `borderStyle` still
-- reserves the 1-cell border in layout (see getBoxMetrics) but paints
-- nothing, since there is no character set registered for it here.
local BOX_CHARS = {
  single = { tl = "\226\148\140", tr = "\226\148\144", bl = "\226\148\148", br = "\226\148\152", h = "\226\148\128", v = "\226\148\130" },
}

local nodeIdCounter = 0
local function nextNodeId()
  nodeIdCounter = nodeIdCounter + 1
  return nodeIdCounter
end

-- Frozen VNode props arrive as a proxy table whose real contents live
-- behind `_store` (see core/element.lua's freezeProps) -- identical
-- unwrapping to host/dom.lua's own `rawProps`.
local function rawProps(props)
  if type(props) ~= "table" then return {} end
  return props._store or props
end

-- ===================== Incremental Yoga sync (dirty tracking) =====================
-- buildYogaTree() below keeps ONE real Yoga node alive per host node across
-- paints (created once, style/children patched incrementally), rather than
-- rebuilding the whole native tree from scratch on every paint() call --
-- see buildYogaTree's own doc comment for why, and YogaNode:free()'s doc
-- comment in yoga_ffi.lua, which already documented this exact "one node
-- per host node, freed individually on removal" model as this binding's
-- intended lifecycle even before anything here actually did it that way.
--
-- `node._styleDirty`/`node._childrenDirty` (set by the mutating Host
-- methods below, cleared by buildYogaTree once it has resynced them) are
-- what let buildYogaTree skip real work for a subtree nothing changed in.
-- A brand-new node (node._yoga == nil) always gets full setup regardless
-- of these flags -- see buildYogaTree's own `isNew` check.

-- A "Text" element's own children (text/Newline/nested-Text nodes) are
-- absorbed into its single flattened Yoga leaf via collectTextLines()'s
-- own separate walk -- buildYogaTree's normal box-children recursion
-- never reaches them at all (Text's own branch never recurses into
-- node.children the way "box" kind nodes do). A mutation on one of these
-- absorbed nodes therefore has to be attributed to the nearest REAL
-- Yoga-owning ancestor: the outermost Text element wrapping it (climbing
-- past any nested Text along the way), not the absorbed node itself.
local function nearestYogaOwner(node)
  local n = node
  while n.parent and n.parent.tag == "Text" do
    n = n.parent
  end
  return n
end

--- Marks the real Yoga-owning ancestor-or-self of `node` as needing its
--- OWN style/content resynced (its props changed, or -- if `node` is
--- absorbed Text content -- the flattened line content the owning Text
--- element derives from it changed).
local function markStyleDirty(node)
  nearestYogaOwner(node)._styleDirty = true
end

--- Marks the real Yoga-owning ancestor-or-self of `node` as needing its
--- Yoga CHILD LIST resynced (an insert/move/removal happened in its
--- direct children). For a node inside a Text element's absorbed
--- content, this is the same as markStyleDirty: Text has no real Yoga
--- children of its own to resync -- any structural change below it is a
--- content change from the owning Text's own perspective.
local function markChildrenDirty(node)
  local owner = nearestYogaOwner(node)
  if owner.tag == "Text" then
    owner._styleDirty = true
  else
    owner._childrenDirty = true
  end
end

-- ===================== Sibling list (intrusive doubly-linked, O(1) structural ops) =====================
-- See this file's own former "KNOWN REMAINING SCALING COST" comment
-- above (now "FIXED SCALING COST") for the full history of why this
-- exists. The MUTATION-facing ground truth for a node's children is now
-- an intrusive doubly-linked list: `parent._firstChild`/`parent._lastChild`
-- point at the ends, and each child carries its own
-- `child._prevSibling`/`child._nextSibling` -- so detachFromParent/
-- appendChild/insertBefore/removeChild below are all O(1) (insertBefore
-- was previously an O(siblings) linear scan for `beforeChild`'s index
-- too, not just an O(siblings) shift -- splicing next to a direct node
-- reference needs neither).
--
-- `node.children`, the plain 1-based Lua array EVERY OTHER function in
-- this file has always consumed (`#node.children`, `node.children[i]` --
-- buildYogaTree, paintNode, resolvePositions, collectTextLines, the
-- scroll-bounds walk, collectPendingWrap, and Transform's isolated
-- sub-render), keeps that exact same name and shape. It is now a LAZILY
-- REBUILT CACHE over the linked list above (see childrenArray() below),
-- invalidated (set to `nil`, not eagerly recomputed) by every mutator on
-- every structural change, and rebuilt at most once per node per paint --
-- the first time something actually reads it as an array -- rather than
-- once per appendChild call. This is what turns the profiled O(N^2)
-- pattern (N appendChild calls in core/reconciler.lua's own
-- "Ensure physical sibling order" loop, each previously touching the
-- array) into real O(N): N O(1) linked-list splices, plus one O(k)
-- (k = that node's own child count, not the whole tree) array rebuild the
-- next time childrenArray() is called for it.
local function childrenArray(node)
  local cached = node.children
  if cached then return cached end
  local list = {}
  local child = node._firstChild
  while child do
    list[#list + 1] = child
    child = child._nextSibling
  end
  node.children = list
  return list
end

--- Detaches `child` from whatever parent it currently has (a no-op if
--- none). Used by appendChild/insertBefore to handle a MOVE (Yoga-owning
--- ancestors on both the old and new side each need their child list
--- resynced) as well as a fresh insert (nothing to detach from yet).
--- O(1): unlinks `child` from its neighbors directly via its own stored
--- `_prevSibling`/`_nextSibling`, no scan needed (see this section's own
--- top comment).
local function detachFromParent(child)
  local parent = child.parent
  if not parent then return end
  local prev, nextSibling = child._prevSibling, child._nextSibling
  if prev then prev._nextSibling = nextSibling else parent._firstChild = nextSibling end
  if nextSibling then nextSibling._prevSibling = prev else parent._lastChild = prev end
  child._prevSibling, child._nextSibling = nil, nil
  parent.children = nil -- invalidate the OLD parent's array cache
  markChildrenDirty(parent)
  child.parent = nil
end

--- Frees `node`'s own persistent Yoga node (if it has one) and recurses
--- into node.children unconditionally -- cheap and correct regardless of
--- node kind, since an absorbed node (see nearestYogaOwner's doc comment)
--- never has a `_yoga` of its own to free, and a Box silently-unsupported
--- inside a Text (see collectTextLines's own doc comment) never got one
--- created in the first place either. Called only from host.removeChild,
--- which -- unlike appendChild/insertBefore -- is only ever used by the
--- Reconciler for a real, permanent removal, never a reorder/move (a move
--- goes through detachFromParent + appendChild/insertBefore without an
--- intervening removeChild call).
local function freeYogaSubtree(node)
  if node._yoga then
    node._yoga:free()
    node._yoga = nil
  end
  local kids = childrenArray(node)
  for i = 1, #kids do
    freeYogaSubtree(kids[i])
  end
end

-- ===================== Layout =====================

local function textStyleOf(props, inherited)
  inherited = inherited or {}
  local style = {
    fg = inherited.fg, bg = inherited.bg, bold = inherited.bold,
    dim = inherited.dim, italic = inherited.italic, underline = inherited.underline,
    strikethrough = inherited.strikethrough, inverse = inherited.inverse,
    href = inherited.href,
  }
  if props then
    if props.color ~= nil then
      local v, present = resolveStyleValue(props.color, true)
      if present then style.fg = terminalColor.resolve(v) end
    end
    if props.backgroundColor ~= nil then
      local v, present = resolveStyleValue(props.backgroundColor, true)
      if present then style.bg = terminalColor.resolve(v) end
    end
    if props.bold ~= nil then
      local v, present = resolveStyleValue(props.bold)
      if present then style.bold = v and true or false end
    end
    if props.dimColor ~= nil then
      local v, present = resolveStyleValue(props.dimColor)
      if present then style.dim = v and true or false end
    end
    if props.italic ~= nil then
      local v, present = resolveStyleValue(props.italic)
      if present then style.italic = v and true or false end
    end
    if props.underline ~= nil then
      local v, present = resolveStyleValue(props.underline)
      if present then style.underline = v and true or false end
    end
    if props.strikethrough ~= nil then
      local v, present = resolveStyleValue(props.strikethrough)
      if present then style.strikethrough = v and true or false end
    end
    if props.inverse ~= nil then
      local v, present = resolveStyleValue(props.inverse)
      if present then style.inverse = v and true or false end
    end
    -- `href` is a text-range style attribute exactly like `color`/`bold`
    -- above (see hydronium_ink/init.lua's HydroniumInkTextProps for why
    -- this rides on Text rather than a separate `<Link>` element), so it
    -- inherits/overrides the same way: a nested `<Text href="...">`
    -- overrides an outer one, and `href = ""` explicitly clears an
    -- inherited link (mirrors `color = "default"` clearing an inherited
    -- fg via terminalColor.resolve above) rather than being ignored.
    if props.href ~= nil then style.href = props.href ~= "" and props.href or nil end
  end
  return style
end

-- Parses the small, style-only SGR vocabulary this host can paint back into
-- cell runs. Transform receives plain text, but its result may use ordinary
-- ANSI styling (as gradient/chalk-style helpers do) without leaking escape
-- bytes into the terminal grid. Deliberately does NOT also parse OSC 8
-- (`\27]8;;uri\27\`) out of `transform()`'s return value -- unlike the SGR
-- vocabulary here, an OSC 8 run has no natural place in this function's
-- output (`runs[n].href` would need a matching close sequence tracked
-- across `append()` calls, and a nested/nonsensical close with no matching
-- open is a real possibility from arbitrary transform() output). A link
-- placed with `<Text href>` around a `<Transform>` is unaffected by this --
-- it is style.href on the OUTER Text's own runs, resolved entirely outside
-- this function; only a link a `transform()` callback tries to fabricate
-- itself from raw escape bytes is not supported, matching this function's
-- existing "standard 8 colors and host text styles" scope statement (see
-- docs/HYDRONIUM_INK_TERMINAL_HOST.md).
local function ansiRuns(text)
  local runs, style, cursor = {}, {}, 1
  local function append(chunk)
    if chunk ~= "" then
      runs[#runs + 1] = {
        text = chunk, fg = style.fg, bg = style.bg, bold = style.bold,
        dim = style.dim, italic = style.italic, underline = style.underline,
        strikethrough = style.strikethrough, inverse = style.inverse,
      }
    end
  end
  local function reset() style = {} end
  while cursor <= #text do
    local startAt, endAt, params = text:find("\27%[([%d;]*)m", cursor)
    if not startAt then append(text:sub(cursor)); break end
    append(text:sub(cursor, startAt - 1))
    if params == "" then reset() else
      -- SGR 0 clears every rendition attribute, including attributes that
      -- happen not to be mentioned by terminalColor.from_sgr's delta table.
      if params == "0" or params:find("^0;") or params:find(";0;") or params:find(";0$") then reset() end
      local fg, bg, flags = terminalColor.from_sgr(params, style.fg, style.bg)
      style.fg, style.bg = fg, bg
      for key, value in pairs(flags) do style[key] = value end
    end
    cursor = endAt + 1
  end
  return runs
end

--- Walks a `Text` intrinsic's own children collecting them into a list
--- of "lines," each line a list of {text, fg, bold} runs. Nested `Text`
--- children are INLINE style overrides merged with the inherited style
--- (real Ink's own semantics -- <Text bold><Text color="red">x</Text></Text>
--- is one styled run, not a nested block); `Newline` ends the current
--- line and starts a new one. A `Box` nested inside a `Text` is not a
--- supported input shape (mirrors real Ink's own constraint) and is
--- silently skipped -- validating author input is out of this module's
--- scope.
local function collectTextLines(node, style)
  local lines = {}
  local current = {}

  local function walk(n, localStyle)
    local kids = childrenArray(n)
    for i = 1, #kids do
      local c = kids[i]
      if c.type == "text" then
        table.insert(current, {
          text = c.text, fg = localStyle.fg, bg = localStyle.bg, bold = localStyle.bold,
          dim = localStyle.dim, italic = localStyle.italic, underline = localStyle.underline,
          strikethrough = localStyle.strikethrough, inverse = localStyle.inverse,
          href = localStyle.href,
        })
      elseif c.type == "element" and c.tag == "Newline" then
        table.insert(lines, current)
        current = {}
      elseif c.type == "element" and c.tag == "Text" then
        walk(c, textStyleOf(c.props, localStyle))
      end
    end
  end

  walk(node, style)
  table.insert(lines, current)
  return lines
end

-- Truncation modes this module implements. Unlike `wrap = "wrap"`/`"hard"`
-- (real reflow, see WRAP_MODES/wrapLine below), truncation never changes
-- the line count -- it only cuts each line to fit.
--
-- With an explicit `width` prop it resolves in one pass, since the width
-- is known up front. Without one it defers to the same two-pass reflow
-- `wrap` uses (see REFLOW_MODES and host.paint()), so a `Text` sized by
-- its container truncates to the width Yoga actually resolved.
local TRUNCATE_MODES = {
  truncate = true, ["truncate-start"] = true, ["truncate-middle"] = true, ["truncate-end"] = true,
}

local function copyRunWith(run, text)
  return {
    text = text, fg = run.fg, bg = run.bg, bold = run.bold, dim = run.dim,
    italic = run.italic, underline = run.underline, strikethrough = run.strikethrough,
    inverse = run.inverse, href = run.href,
  }
end

--- Truncates one `collectTextLines()` line (a list of styled runs) to fit
--- `width` CELLS (not bytes or codepoints -- see hydronium_ink.text_metrics),
--- preserving per-run styling at the cut boundary as best it can. Uses a
--- plain ASCII "..." marker, not a real Unicode ellipsis glyph (U+2026),
--- purely to keep the marker's own width trivially == its character count
--- without consulting text_metrics for it too.
--- @param line table[] Array of {text, fg, bg, bold, ...} runs.
--- @param width integer
--- @param mode "truncate"|"truncate-start"|"truncate-middle"|"truncate-end"
--- @return table[] truncated line
local function truncateLine(line, width, mode)
  if width < 0 then width = 0 end
  local total = 0
  for _, run in ipairs(line) do total = total + textMetrics.displayWidth(run.text) end
  if total <= width then return line end
  if width == 0 or #line == 0 then return {} end

  local marker = ("..."):sub(1, math.min(3, width))
  local keep = math.max(width - #marker, 0)

  -- Walks `line`'s runs as a flat stream of {text, run} grapheme clusters,
  -- so a cut never lands inside a multi-byte character. `keep` is a cell
  -- budget: a wide (2-cell) cluster that would overshoot it is dropped
  -- rather than split.
  local function takeFromStart(n)
    local result, remaining = {}, n
    for _, run in ipairs(line) do
      if remaining <= 0 then break end
      local kept = {}
      for _, g in ipairs(textMetrics.clusters(run.text)) do
        if g.width > remaining then break end
        kept[#kept + 1] = g.text
        remaining = remaining - g.width
      end
      if #kept > 0 then
        table.insert(result, copyRunWith(run, table.concat(kept)))
      end
    end
    return result
  end

  local function takeFromEnd(n)
    local result, remaining = {}, n
    for i = #line, 1, -1 do
      if remaining <= 0 then break end
      local run = line[i]
      local clusters = textMetrics.clusters(run.text)
      local kept = {}
      for j = #clusters, 1, -1 do
        local g = clusters[j]
        if g.width > remaining then break end
        table.insert(kept, 1, g.text)
        remaining = remaining - g.width
      end
      if #kept > 0 then
        table.insert(result, 1, copyRunWith(run, table.concat(kept)))
      end
    end
    return result
  end

  if mode == "truncate-start" then
    local result = { copyRunWith(line[1], marker) }
    for _, r in ipairs(takeFromEnd(keep)) do table.insert(result, r) end
    return result
  elseif mode == "truncate-middle" then
    local headLen = math.floor(keep / 2)
    local result = takeFromStart(headLen)
    table.insert(result, copyRunWith(line[#line], marker))
    for _, r in ipairs(takeFromEnd(keep - headLen)) do table.insert(result, r) end
    return result
  else -- "truncate" or "truncate-end"
    local result = takeFromStart(keep)
    table.insert(result, copyRunWith(line[#line], marker))
    return result
  end
end

-- `wrap`/`hard` modes: real reflow, unlike TRUNCATE_MODES above. `wrap`
-- pushes a single word wider than the target width onto its own
-- (overflowing) line without splitting it; `hard` always fills every
-- line to `width`, splitting mid-word if it has to -- matching real
-- Ink's own documented distinction between the two.
local WRAP_MODES = { wrap = true, hard = true }

-- Every mode that needs a width before it can produce its final lines.
-- With an explicit `width` prop all of them resolve in one pass; without
-- one they all defer to host.paint()'s two-pass reflow, which learns the
-- real width from Yoga and then reflows against it.
--
-- Truncation used to be excluded here, which meant `wrap = "truncate"` on
-- a Text sized by its container did nothing at all: it fell through every
-- branch and overflowed, with no error and no warning. Asking for
-- truncation and silently getting overflow is worse than not offering it,
-- and the two-pass machinery wrap already needed answers it exactly.
local REFLOW_MODES = {}
for mode in pairs(WRAP_MODES) do REFLOW_MODES[mode] = true end
for mode in pairs(TRUNCATE_MODES) do REFLOW_MODES[mode] = true end

local function isSpaceCluster(text)
  return text == " "
end

--- Coalesces a flat grapheme-cluster stream (each tagged with the run/
--- style it came from) back into styled runs, merging consecutive
--- clusters that share the same originating run.
local function graphemesToRuns(graphemes)
  local runs = {}
  local curStyle, curText = nil, {}
  for _, g in ipairs(graphemes) do
    if g.style ~= curStyle then
      if curStyle then table.insert(runs, copyRunWith(curStyle, table.concat(curText))) end
      curStyle, curText = g.style, {}
    end
    table.insert(curText, g.text)
  end
  if curStyle then table.insert(runs, copyRunWith(curStyle, table.concat(curText))) end
  return runs
end

--- Flattens `line` (a list of styled runs) into one grapheme-cluster
--- stream, then groups it into whitespace-delimited "tokens" (a maximal
--- run of space clusters, or a maximal run of non-space clusters) --
--- the unit `wrapLine` below actually wraps at.
local function tokenizeLine(line)
  local graphemes = {}
  for _, run in ipairs(line) do
    for _, g in ipairs(textMetrics.clusters(run.text)) do
      table.insert(graphemes, { text = g.text, width = g.width, style = run })
    end
  end

  local tokens = {}
  local i, n = 1, #graphemes
  while i <= n do
    local spaceTok = isSpaceCluster(graphemes[i].text)
    local j = i
    local width = 0
    while j <= n and isSpaceCluster(graphemes[j].text) == spaceTok do
      width = width + graphemes[j].width
      j = j + 1
    end
    local tokGraphemes = {}
    for k = i, j - 1 do table.insert(tokGraphemes, graphemes[k]) end
    table.insert(tokens, { graphemes = tokGraphemes, width = width, isSpace = spaceTok })
    i = j
  end
  return tokens, #graphemes
end

--- Real word-wrap: breaks one `collectTextLines()` line into one or more
--- output lines (each a list of styled runs, same shape as the input) so
--- none exceeds `width` cells, breaking at whitespace where possible. A
--- word wider than `width` on its own either gets its own (overflowing)
--- line (`hard = false`) or is split mid-word across lines (`hard =
--- true`). Preserves per-cluster styling exactly like `truncateLine`.
--- @param line table[] Array of {text, fg, bg, bold, ...} runs.
--- @param width integer
--- @param hard boolean
--- @return table[][] one or more output lines
local function wrapLine(line, width, hard)
  local tokens, graphemeCount = tokenizeLine(line)
  if width <= 0 or graphemeCount == 0 then return { line } end

  local outLines = {}
  local current, currentWidth = {}, 0

  local function pushLine()
    table.insert(outLines, graphemesToRuns(current))
    current, currentWidth = {}, 0
  end

  for _, tok in ipairs(tokens) do
    if tok.isSpace then
      if #current > 0 then
        if currentWidth + tok.width <= width then
          for _, g in ipairs(tok.graphemes) do table.insert(current, g) end
          currentWidth = currentWidth + tok.width
        else
          pushLine()
        end
      end
    elseif tok.width <= width then
      if currentWidth + tok.width > width then pushLine() end
      for _, g in ipairs(tok.graphemes) do table.insert(current, g) end
      currentWidth = currentWidth + tok.width
    elseif hard then
      for _, g in ipairs(tok.graphemes) do
        if currentWidth + g.width > width and currentWidth > 0 then pushLine() end
        table.insert(current, g)
        currentWidth = currentWidth + g.width
      end
    else
      -- Oversized word, non-hard wrap: its own line, left unsplit.
      if #current > 0 then pushLine() end
      for _, g in ipairs(tok.graphemes) do table.insert(current, g) end
      currentWidth = tok.width
      pushLine()
    end
  end
  if #current > 0 or #outLines == 0 then pushLine() end

  return outLines
end

-- "Undefined" in Yoga's own sense (its C headers `#define YGUndefined
-- NAN` -- not a linkable symbol, just a NaN float). Used as the root's
-- available width/height when this host has no known real terminal
-- size yet (host._cols/_rows unset -- e.g. a non-interactive/piped run,
-- or a test that never calls host.setSize()), in which case the root
-- auto-sizes to its content, matching this module's original
-- behavior. When a real size IS known, host.paint() passes it instead
-- so the root -- and therefore percentage widths/heights, flexGrow,
-- and alignItems: stretch throughout the tree -- are resolved against
-- the actual terminal, not against content.
local YG_UNDEFINED = 0 / 0

-- Forward declarations: Transform's own buildYogaTree branch (below)
-- renders its children into a fully isolated sub-tree, using these same
-- functions (each real, defined later in this file) to do so -- rather
-- than duplicating the build/layout/paint pipeline a second time.
local cell
local resolvePositions
local newFrame
local paintNode

--- Syncs `node` (and, for a "box"-kind node, its whole subtree) against a
--- real, PERSISTENT Yoga node: created once per host node
--- (`node._yoga`, kept alive across paints -- see this file's own
--- "Incremental Yoga sync" section above), and thereafter patched
--- in place rather than torn down and rebuilt every paint(). A brand-new
--- node (no `node._yoga` yet) always gets full style/children setup;
--- an existing one only resyncs its style when `node._styleDirty` and
--- its Yoga child list when `node._childrenDirty` (both set by the
--- mutating Host methods below, cleared here once resynced) -- but a
--- "box"-kind node still always RECURSES into its existing children
--- regardless of its own `_childrenDirty`, so a dirty grandchild several
--- levels down still gets resynced even when nothing on the path to it
--- structurally changed.
--- `node._layoutKind`/`node._layoutLines` (fields this module owns
--- exclusively, like the old `node._layout` was) are what
--- `resolvePositions()` below reads back after `calculateLayout()`.
--- TRANSFORM IS THE ONE EXCEPTION: it always fully recomputes regardless
--- of dirty flags (see its own branch below for why) -- everything else
--- gets the skip-when-unchanged treatment.
local function buildYogaTree(node)
  local isNew = node._yoga == nil
  local yg = node._yoga or Yoga.newNode()
  node._yoga = yg

  if node.type == "text" then
    node._layoutKind = "text"
    if isNew or node._styleDirty then
      yg:setStyle({ width = textMetrics.displayWidth(node.text), height = 1 })
      node._styleDirty = false
    end
    return yg
  end

  if node.type == "element" and node.tag == "Newline" then
    node._layoutKind = "newline"
    if isNew then
      yg:setStyle({ width = 0, height = 1 })
    end
    return yg
  end

  if node.type == "element" and node.tag == "Spacer" then
    -- No props (see hydronium_ink/init.lua) -- a real Yoga flexGrow=1
    -- leaf, matching real Ink's own Spacer exactly. Treated as a "box"
    -- kind purely so resolvePositions()'s existing "only box kinds have
    -- their own Yoga-inserted children" rule stays correct (a Spacer
    -- never has children in practice, but this keeps its code path
    -- identical to a childless Box rather than inventing a new kind).
    node._layoutKind = "box"
    if isNew then
      yg:setStyle({ flexGrow = 1 })
    end
    return yg
  end

  if node.type == "element" and node.tag == "Transform" then
    -- Renders `node.children` into a fully isolated sub-tree and frame,
    -- extracts each row as PLAIN text and calls
    -- `props.transform(line, index)` on each (1-indexed, not real Ink's
    -- 0-indexed convention). The transformed strings become this node's
    -- own "transform_block" content -- from the OUTER tree's
    -- perspective, a Transform is a fixed-size leaf, exactly like a Text.
    -- Returned ANSI SGR sequences are parsed into ordinary styled cell runs.
    --
    -- Always fully recomputed, ignoring dirty flags entirely (unlike
    -- every other branch here): this node's content depends on its
    -- CHILDREN's rendered output, and nearestYogaOwner (see this file's
    -- "Incremental Yoga sync" section) only bubbles a mutation up through
    -- Text-tag ancestors, not Transform ones -- there is no cheap way to
    -- know from here whether something inside actually changed, so this
    -- always redoes the whole isolated render pass, matching its cost
    -- before persistence was added anywhere else in this file.
    --
    -- `anonymousRoot` -- unlike every other node reached from here -- is
    -- a genuinely fresh, throwaway Lua table on every single call (never
    -- the same object twice, never referenced again after this branch
    -- returns), so its own Yoga node is always brand new and always safe
    -- to free again immediately below. Its `_firstChild`/`_lastChild`,
    -- though, point into the REAL sibling linked list `node`'s own
    -- children live on (see this file's own "Sibling list" section) --
    -- the actual persistent host nodes, reused across paints and
    -- potentially still holding a `_yoga` from a PRIOR Transform call.
    -- This works without copying anything because childrenArray()/
    -- buildYogaTree() below only ever walk FORWARD via each child's own
    -- `_nextSibling`, which is a property of the child, not of whichever
    -- object is doing the reading -- `anonymousRoot` never needs its own
    -- copy of the list, just a starting pointer into the shared one.
    -- `removeAllChildren()` before freeing `isolatedRootYg` detaches the
    -- childrens' YOGA nodes cleanly without touching this shared sibling
    -- linked list or `.parent` at all, so they stay valid and reusable
    -- for next time (or for freeYogaSubtree, whenever they're genuinely
    -- unmounted via host.removeChild -- never triggered from here).
    local anonymousRoot = {
      id = nextNodeId(), type = "root", tag = "TransformRoot",
      props = {}, parent = nil,
      _firstChild = node._firstChild, _lastChild = node._lastChild,
    }
    local isolatedRootYg = buildYogaTree(anonymousRoot)
    isolatedRootYg:calculateLayout(YG_UNDEFINED, YG_UNDEFINED)
    resolvePositions(anonymousRoot, 1, 1)

    local isolatedLayout = anonymousRoot._layout
    local iw, ih = math.max(isolatedLayout.w, 0), math.max(isolatedLayout.h, 0)
    local tempFrame = newFrame(iw, ih)
    paintNode(anonymousRoot, tempFrame)
    isolatedRootYg:removeAllChildren()
    isolatedRootYg:free()

    local plainLines = {}
    for y = 1, ih do
      local chars = {}
      for x = 1, iw do
        chars[x] = tempFrame.rows[y][x].ch
      end
      plainLines[y] = table.concat(chars)
    end
    if #plainLines == 0 then plainLines = { "" } end

    local transform = (node.props or {}).transform
    local transformedLines = {}
    local w = 0
    for i, line in ipairs(plainLines) do
      local out = line
      if type(transform) == "function" then
        local ok, result = pcall(transform, line, i)
        if ok and type(result) == "string" then out = result end
      end
      local runs = ansiRuns(out)
      transformedLines[i] = runs
      local ow = 0
      for _, run in ipairs(runs) do ow = ow + textMetrics.displayWidth(run.text) end
      if ow > w then w = ow end
    end

    node._layoutKind = "transform_block"
    node._layoutLines = transformedLines
    yg:setStyle({ width = w, height = math.max(#transformedLines, 1) })
    return yg
  end

  if node.type == "element" and node.tag == "Text" then
    node._layoutKind = "text_block"
    local props = node.props or {}
    -- A wrap mode with NO explicit width can't use the isNew/_styleDirty
    -- skip like everything else here: its correct wrapped content
    -- depends on its PARENT's resolved width (via Yoga's own
    -- flex/stretch -- see the two-pass reflow below), which can change
    -- for reasons that have nothing to do with this node's own props or
    -- content at all (a sibling's flexGrow, a terminal resize). Always
    -- recomputing this specific case is the conservative, definitely-
    -- correct choice; every other Text -- the overwhelming majority,
    -- including explicit-width wrap and all truncate modes, whose
    -- content genuinely depends only on their own props -- gets the
    -- normal skip-when-unchanged treatment.
    local isWrapNoWidth = REFLOW_MODES[props.wrap] and not props.width
    -- A `ink.byProfile`/`ink.adaptive` prop resolves against
    -- `currentColorProfile` (see `resolveStyleValue` above) INSIDE
    -- `textStyleOf`, called only here -- so a Text node using one that
    -- neither gained a `_styleDirty` prop change nor hit the wrap-reflow
    -- case above still needs recomputing whenever the profile itself has
    -- changed since the last time this ran (host.setColorProfile, or Ink
    -- Lab switching the live preview profile), or it would keep painting
    -- whichever profile happened to be active the first time it rendered.
    local isProfileStale = node._lastColorProfile ~= currentColorProfile

    if isNew or node._styleDirty or isWrapNoWidth or isProfileStale then
      local lines = collectTextLines(node, textStyleOf(props))
      node._lastColorProfile = currentColorProfile
      node._pendingWrap = nil

      if props.width and TRUNCATE_MODES[props.wrap] then
        for i, line in ipairs(lines) do
          lines[i] = truncateLine(line, props.width, props.wrap)
        end
      elseif props.width and WRAP_MODES[props.wrap] then
        -- Width is already known up front -- wrap right now, no second
        -- pass needed (unlike the no-explicit-width case below).
        local wrapped = {}
        for _, line in ipairs(lines) do
          for _, wline in ipairs(wrapLine(line, props.width, props.wrap == "hard")) do
            table.insert(wrapped, wline)
          end
        end
        lines = wrapped
      elseif node._prewrapWidth and REFLOW_MODES[props.wrap] then
        -- Pass 2 of the two-pass reflow host.paint() runs for a wrap or
        -- truncate mode with no explicit width (see its own doc comment):
        -- use the lines already reflowed there, against pass 1's real
        -- resolved width.
        lines = node._prewrapLines
      elseif REFLOW_MODES[props.wrap] then
        -- Pass 1: no explicit width yet, so there is nothing to reflow
        -- against -- give Yoga the natural (unreflowed) width so its own
        -- flex/stretch can resolve this node's real available width, and
        -- flag it for host.paint() to reflow and rerun layout once more.
        node._pendingWrap = props.wrap
      end

      local w = 0
      for _, line in ipairs(lines) do
        local lw = 0
        for _, run in ipairs(line) do lw = lw + textMetrics.displayWidth(run.text) end
        if lw > w then w = lw end
      end

      -- Pass 1 of a no-explicit-width wrap (node._pendingWrap just got set
      -- above) is the one case that must leave `width` UNSET rather than
      -- pinning it to `w`: yoga_ffi's setStyle only calls
      -- YGNodeStyleSetWidth when given a non-nil width, and an explicit
      -- width -- even one meant only as a "natural size" hint -- always
      -- wins over alignItems: stretch in real Yoga, blocking exactly the
      -- flex/stretch resolution host.paint()'s second pass depends on to
      -- learn this node's real available width. Every other case (a normal
      -- unwrapped Text, an explicit-width Text, or pass 2 re-running with
      -- node._prewrapWidth pinned) still wants an explicit width.
      local yogaWidth = w
      if props.width then
        yogaWidth = props.width
      elseif node._prewrapWidth and REFLOW_MODES[props.wrap] then
        yogaWidth = node._prewrapWidth
      elseif node._pendingWrap then
        yogaWidth = nil
      end
      node._layoutLines = lines
      yg:setStyle({ width = yogaWidth, height = math.max(#lines, 1) })
      node._styleDirty = false
    end
    return yg
  end

  -- Box (tag == "Box") and the implicit root container (its `props` table
  -- is always `{}` -- see createTerminalHost below) share this same
  -- style mapping; Yoga's own flex algorithm (grow/shrink/wrap/justify/
  -- align, auto-sizing from children when width/height are unset) replaces
  -- what used to be this module's own hand-rolled block-stacking math.
  node._layoutKind = "box"

  if isNew or node._styleDirty then
    local props = node.props or {}
    yg:setStyle({
      flexDirection = props.flexDirection == "row" and "row" or "column",
      justifyContent = props.justifyContent,
      alignItems = props.alignItems,
      flexWrap = props.flexWrap,
      flexGrow = props.flexGrow,
      flexShrink = props.flexShrink,
      flexBasis = props.flexBasis,
      width = props.width,
      height = props.height,
      padding = props.padding,
      paddingX = props.paddingX,
      paddingY = props.paddingY,
      border = props.borderStyle and 1 or nil,
      margin = props.margin,
      marginX = props.marginX,
      marginY = props.marginY,
      position = props.position,
      top = props.top,
      right = props.right,
      bottom = props.bottom,
      left = props.left,
      display = props.display,
      overflow = props.overflow,
    })
    node._styleDirty = false
  end

  -- Always recurse into every existing child regardless of our OWN
  -- _childrenDirty -- a grandchild several levels down can still have its
  -- own _styleDirty/_childrenDirty pending even when nothing on the path
  -- to it structurally changed. Only the actual Yoga child-list wiring
  -- (removeAllChildren + reinsert) is skipped when this node's own child
  -- list genuinely didn't change.
  local childListChanged = isNew or node._childrenDirty
  if childListChanged then
    yg:removeAllChildren()
  end
  local kids = childrenArray(node)
  for i = 1, #kids do
    local childYg = buildYogaTree(kids[i])
    if childListChanged then
      yg:insertChild(childYg, i - 1) -- Yoga child indices are 0-based
    end
  end
  node._childrenDirty = false

  return yg
end

--- Rounds a non-negative Yoga layout float to a whole terminal cell.
--- Yoga's own arithmetic (flexGrow division that doesn't divide evenly,
--- etc.) can produce non-integer results even though every size this
--- module ever feeds it (text lengths, line counts, explicit
--- width/height/padding/border props) is an integer -- cells are
--- discrete, so this module always needs whole numbers, not fractional
--- pixels. Concatenating a float straight into an ANSI escape sequence
--- (e.g. `"\27[" .. y .. ";1H"`) would also literally emit "3.0" instead
--- of "3", which real terminals do not accept -- rounding here, once,
--- is what keeps every downstream user of `node._layout` (paintNode,
--- newFrame, the cursor-move sequences in host.paint()) working with
--- plain integers exactly as before this Yoga swap.
cell = function(value)
  return math.floor(value + 0.5)
end

--- Top-down pass converting Yoga's per-node parent-relative
--- left/top/width/height (read via `node._yoga:getComputedLayout()`,
--- valid only after `calculateLayout()` has run on the root) into this
--- module's own absolute, 1-indexed `node._layout` -- the same shape
--- paintNode() below has always consumed, so painting itself needed no
--- changes for this Yoga swap.
resolvePositions = function(node, parentX, parentY)
  local computed = node._yoga:getComputedLayout()
  local x, y = parentX + cell(computed.left), parentY + cell(computed.top)

  node._layout = {
    x = x, y = y, w = cell(computed.width), h = cell(computed.height),
    -- Captured here into a plain Lua table (rather than having
    -- measureElement() read the Yoga node lazily) so that reading a
    -- node's last-painted layout never depends on its persistent Yoga
    -- node still being alive -- e.g. after host.removeChild() has since
    -- freed it (see freeYogaSubtree's own doc comment).
    clientW = cell(computed.clientWidth), clientH = cell(computed.clientHeight),
    kind = node._layoutKind, lines = node._layoutLines,
  }

  -- Only "box" nodes got real Yoga children inserted in buildYogaTree()
  -- (a "text_block" node's own `node.children` are raw text/Newline nodes
  -- already fully absorbed into `node._layoutLines` there, matching the
  -- old position()'s identical "only recurse for kind == box" rule) -- a
  -- text/newline/text_block node's `node.children`, if any, were never
  -- given their own Yoga node and must not be recursed into here.
  if node._layoutKind == "box" then
    local kids = childrenArray(node)
    for i = 1, #kids do
      resolvePositions(kids[i], x, y)
    end
  end
end

-- ===================== Frame buffer + painting =====================

newFrame = function(w, h)
  local frame = { w = w, h = h, rows = {} }
  for r = 1, h do
    local row = {}
    for c = 1, w do
      row[c] = {
        ch = " ", fg = nil, bg = nil, bold = false, dim = false,
        italic = false, underline = false, strikethrough = false, inverse = false,
        href = nil,
      }
    end
    frame.rows[r] = row
  end
  return frame
end

--- OSC 8 HYPERLINK GRID REPRESENTATION (design decision, read before
--- touching `href` anywhere in this file): a link is a PER-CELL STYLE
--- ATTRIBUTE, exactly like `fg`/`bold` above -- not a separate span/segment
--- list layered on top of the grid, and not bytes embedded in `ch`/`.text`.
--- This was the natural choice, not an arbitrary one: every other piece of
--- Text styling in this module (color, bold, underline, ...) already flows
--- as a plain field on the same run/cell tables all the way from
--- `textStyleOf` through `collectTextLines`/`copyRunWith` to `setCell`, and
--- reuses the exact same "coalesce a run of cells sharing a style" logic
--- `encodeRun` below already has for SGR (see `styleKey`/`cellsDiffer`,
--- both extended to include `href`). A separate span list would have needed
--- its own coalescing, its own diffing, and its own reconciliation with the
--- character grid's own edits -- solving the same problem `styleKey` already
--- solves, a second time, for no real benefit. Treating it as a style
--- attribute (rather than encoding it into `ch`) is also what keeps it
--- zero-width for free: `textMetrics.displayWidth`/`clusters` only ever see
--- `run.text`, which never contains the URI or any OSC bytes -- see
--- `host.paint()`'s own hyperlink-capability handling below for where the
--- OSC 8 bytes actually get synthesized (only at encode time, per run).
---
--- @param style table|nil {fg, bg, bold, dim, italic, underline, strikethrough, inverse, href}
--- @param clip table|nil {x1, y1, x2, y2} -- cells outside this rect are
---   silently dropped, same as cells outside the frame itself. Set by
---   paintNode() for a `Box` with `overflow = "hidden"` or `"scroll"`.
---   Scroll boxes additionally translate their children by their controlled,
---   clamped `scrollTop`/`scrollLeft` offsets before this clip is applied.
local function setCell(frame, x, y, ch, style, clip)
  if y < 1 or y > frame.h or x < 1 or x > frame.w then return end
  if clip and (x < clip.x1 or x > clip.x2 or y < clip.y1 or y > clip.y2) then return end
  style = style or {}
  frame.rows[y][x] = {
    ch = ch, fg = style.fg, bg = style.bg, bold = style.bold or false,
    dim = style.dim or false, italic = style.italic or false,
    underline = style.underline or false, strikethrough = style.strikethrough or false,
    inverse = style.inverse or false, href = style.href,
  }
end

--- Paints `text` starting at cell (x, y), one grapheme cluster per
--- iteration (see hydronium_ink.text_metrics) instead of one BYTE per
--- cell -- the previous model, which split every multi-byte UTF-8
--- character across as many cells as it had bytes. A 2-cell-wide
--- cluster (CJK, most emoji) writes its full text into its first cell
--- and an empty "continuation" cell right after: real terminals advance
--- the cursor two columns for one wide glyph on their own, so the
--- continuation cell must stay empty (not a space -- that would consume
--- a THIRD column) for the grid's column accounting to stay correct.
--- @return integer the next cx after the painted text
local function paintClusters(frame, x, y, text, style, clip)
  local cx = x
  for _, g in ipairs(textMetrics.clusters(text)) do
    setCell(frame, cx, y, g.text, style, clip)
    cx = cx + 1
    if g.width >= 2 then
      setCell(frame, cx, y, "", style, clip)
      cx = cx + 1
    end
  end
  return cx
end

--- Resolves one border edge's color/dim, falling back from the specific
--- `border<Edge>Color`/`border<Edge>DimColor` prop to the box-wide
--- `borderColor`/`borderDimColor`. Corners (see paintNode below) use the
--- box-wide fallback directly rather than picking one of their two
--- adjacent edges -- a stated, documented simplification, since a corner
--- genuinely belongs to two edges at once and real Ink's own behavior
--- there was not verified against for this module.
--- @return integer|nil fg, boolean dim
local function resolveBorderEdge(props, edgeName)
  local color = props["border" .. edgeName .. "Color"] or props.borderColor
  local dim = props["border" .. edgeName .. "DimColor"]
  if dim == nil then dim = props.borderDimColor end
  if color ~= nil then
    local v, present = resolveStyleValue(color, true)
    color = present and v or nil
  end
  if dim ~= nil then
    local v, present = resolveStyleValue(dim)
    dim = present and v or nil
  end
  return color and terminalColor.resolve(color), dim and true or false
end

paintNode = function(node, frame, clip, offsetX, offsetY)
  local layout = node._layout
  offsetX, offsetY = offsetX or 0, offsetY or 0

  if layout.kind == "box" then
    local props = node.props or {}
    local x1, y1 = layout.x + offsetX, layout.y + offsetY
    local x2, y2 = layout.x + layout.w - 1, layout.y + layout.h - 1
    local bg
    if props.backgroundColor ~= nil then
      local v, present = resolveStyleValue(props.backgroundColor, true)
      bg = present and v and terminalColor.resolve(v) or nil
    end

    if bg then
      for y = y1, y2 do
        for x = x1, x2 do
          setCell(frame, x, y, " ", { bg = bg }, clip)
        end
      end
    end

    if props.borderStyle then
      local chars = BOX_CHARS[props.borderStyle]
      if chars then
        local baseFg
        if props.borderColor ~= nil then
          local v, present = resolveStyleValue(props.borderColor, true)
          baseFg = present and v and terminalColor.resolve(v) or nil
        end
        local baseDim = false
        if props.borderDimColor ~= nil then
          local v, present = resolveStyleValue(props.borderDimColor)
          baseDim = present and v and true or false
        end
        local topFg, topDim = resolveBorderEdge(props, "Top")
        local rightFg, rightDim = resolveBorderEdge(props, "Right")
        local bottomFg, bottomDim = resolveBorderEdge(props, "Bottom")
        local leftFg, leftDim = resolveBorderEdge(props, "Left")

        setCell(frame, x1, y1, chars.tl, { fg = baseFg, bg = bg, dim = baseDim }, clip)
        setCell(frame, x2, y1, chars.tr, { fg = baseFg, bg = bg, dim = baseDim }, clip)
        setCell(frame, x1, y2, chars.bl, { fg = baseFg, bg = bg, dim = baseDim }, clip)
        setCell(frame, x2, y2, chars.br, { fg = baseFg, bg = bg, dim = baseDim }, clip)
        for x = x1 + 1, x2 - 1 do
          setCell(frame, x, y1, chars.h, { fg = topFg, bg = bg, dim = topDim }, clip)
          setCell(frame, x, y2, chars.h, { fg = bottomFg, bg = bg, dim = bottomDim }, clip)
        end
        for y = y1 + 1, y2 - 1 do
          setCell(frame, x1, y, chars.v, { fg = leftFg, bg = bg, dim = leftDim }, clip)
          setCell(frame, x2, y, chars.v, { fg = rightFg, bg = bg, dim = rightDim }, clip)
        end
      end
    end

    local childClip = clip
    if props.overflow == "hidden" or props.overflow == "scroll" then
      childClip = { x1 = x1, y1 = y1, x2 = x2, y2 = y2 }
      if clip then
        childClip.x1 = math.max(childClip.x1, clip.x1)
        childClip.y1 = math.max(childClip.y1, clip.y1)
        childClip.x2 = math.min(childClip.x2, clip.x2)
        childClip.y2 = math.min(childClip.y2, clip.y2)
      end
    end

    local childOffsetX, childOffsetY = offsetX, offsetY
    if props.overflow == "scroll" then
      -- Controlled offsets compose with a signal and useInput; the host does
      -- not impose a hidden keyboard policy on a scrollable view.
      local contentRight, contentBottom = layout.x - 1, layout.y - 1
      local scrollKids = childrenArray(node)
      for i = 1, #scrollKids do
        local childLayout = scrollKids[i]._layout
        if childLayout then
          contentRight = math.max(contentRight, childLayout.x + childLayout.w - 1)
          contentBottom = math.max(contentBottom, childLayout.y + childLayout.h - 1)
        end
      end
      local maxLeft = math.max(contentRight - (layout.x + layout.w - 1), 0)
      local maxTop = math.max(contentBottom - (layout.y + layout.h - 1), 0)
      local requestedLeft = math.max(0, math.floor(tonumber(props.scrollLeft) or 0))
      local requestedTop = math.max(0, math.floor(tonumber(props.scrollTop) or 0))
      local left, top = math.min(requestedLeft, maxLeft), math.min(requestedTop, maxTop)
      node._scroll = {
        left = left, top = top, maxLeft = maxLeft, maxTop = maxTop,
        width = math.max(contentRight - layout.x + 1, 0),
        height = math.max(contentBottom - layout.y + 1, 0),
      }
      childOffsetX, childOffsetY = offsetX - left, offsetY - top
    else
      node._scroll = nil
    end

    local paintKids = childrenArray(node)
    for i = 1, #paintKids do
      paintNode(paintKids[i], frame, childClip, childOffsetX, childOffsetY)
    end
  elseif layout.kind == "text_block" then
    for i, line in ipairs(layout.lines) do
      local cx = layout.x + offsetX
      local cy = layout.y + offsetY + i - 1
      for _, run in ipairs(line) do
        cx = paintClusters(frame, cx, cy, run.text, run, clip)
      end
    end
  elseif layout.kind == "text" then
    -- Bare text directly under a Box (no enclosing <Text>) -- see the
    -- "text" kind's doc comment on measure() above.
    paintClusters(frame, layout.x + offsetX, layout.y + offsetY, node.text, nil, clip)
  elseif layout.kind == "transform_block" then
    for i, line in ipairs(layout.lines) do
      local cx = layout.x + offsetX
      for _, run in ipairs(line) do
        cx = paintClusters(frame, cx, layout.y + offsetY + i - 1, run.text, run, clip)
      end
    end
  end
  -- "newline": nothing to paint -- it already reserved its space during
  -- measure()/position().
end

local DEFAULT_STYLE_KEY = "-1:-1:0:0:0:0:0:0"

-- Includes `href` (or the empty string for "no link") so a run of cells
-- that share every SGR attribute but differ in their hyperlink target
-- still get coalesced into SEPARATE encodeRun() groups below -- otherwise
-- two adjacent same-colored links (or a link immediately followed by
-- plain text of the same color) would merge into one OSC 8 span covering
-- both, which is wrong regardless of `hyperlinkCapability` (see
-- host.paint()'s own hyperlink handling: capability only gates whether
-- the OSC 8 bytes are ever emitted, not whether runs are split by href).
local function styleKey(cell)
  return terminalColor.key(cell.fg) .. ":" .. terminalColor.key(cell.bg) .. ":"
    .. (cell.bold and 1 or 0) .. ":" .. (cell.dim and 1 or 0) .. ":"
    .. (cell.italic and 1 or 0) .. ":" .. (cell.underline and 1 or 0) .. ":"
    .. (cell.strikethrough and 1 or 0) .. ":" .. (cell.inverse and 1 or 0) .. ":"
    .. (cell.href or "")
end

local function sgrFor(cell, colorCapability)
  local seq = "\27[0m"
  if cell.bold then seq = seq .. "\27[1m" end
  if cell.dim then seq = seq .. "\27[2m" end
  if cell.italic then seq = seq .. "\27[3m" end
  if cell.underline then seq = seq .. "\27[4m" end
  if cell.inverse then seq = seq .. "\27[7m" end
  if cell.strikethrough then seq = seq .. "\27[9m" end
  seq = seq .. terminalColor.sgr(cell.fg, false, colorCapability)
  seq = seq .. terminalColor.sgr(cell.bg, true, colorCapability)
  return seq
end

-- OSC 8 hyperlink open/close, exactly the two sequences named in this
-- package's own mission brief (`ESC ]8;;<uri>ESC \<text>ESC ]8;;ESC \`):
-- the closing form repeats the same `ESC ]8;;` header with an empty URI,
-- which is what tells a real terminal "hyperlink span ends here" rather
-- than "here is a link to the empty string". ST (`ESC \`) is used as the
-- terminator (not BEL) to match that literal spec text and because ST is
-- the more broadly-recommended terminator in the wild (iTerm2, kitty,
-- WezTerm, and tmux's passthrough all accept it; BEL is the older,
-- less-preferred alternative some of the same docs still mention).
local OSC8_HEADER = "\27]8;;"
local OSC8_TERMINATOR = "\27\\"
local function oscHyperlinkOpen(uri)
  return OSC8_HEADER .. uri .. OSC8_TERMINATOR
end
local OSC8_CLOSE = OSC8_HEADER .. OSC8_TERMINATOR

--- Encodes columns [c1..c2] of `row` as a byte string, switching SGR
--- state only when the active style actually changes cell-to-cell (real
--- style-run coalescing, not a fresh reset+code pair on every
--- character) and leaving the terminal in the default (reset) style
--- when the run ends on anything but the default, so a subsequent
--- unrelated write (a shell prompt, a later diff run) never inherits a
--- stray color. `hyperlinkCapability` (see host.setHyperlinkCapability's
--- own doc comment) gates OSC 8 emission independently of `colorCapability`:
--- when it is false, `cell.href` is read for run-splitting purposes only
--- (via styleKey above) and NO escape bytes are ever written for it -- the
--- run's plain visible text comes out exactly as it would with no link at
--- all, which is the whole point of the capability gate (a terminal not
--- known to support OSC 8 must never see raw `]8;;...` bytes as garbage).
local function encodeRun(row, c1, c2, colorCapability, hyperlinkCapability)
  local parts = {}
  local lastKey = nil
  local openLink = nil -- the href (if any) the currently-open OSC 8 span covers
  for x = c1, c2 do
    local cell = row[x]
    local key = styleKey(cell)
    if key ~= lastKey then
      if openLink then
        table.insert(parts, OSC8_CLOSE)
        openLink = nil
      end
      table.insert(parts, sgrFor(cell, colorCapability))
      lastKey = key
      if hyperlinkCapability and cell.href then
        table.insert(parts, oscHyperlinkOpen(cell.href))
        openLink = cell.href
      end
    end
    table.insert(parts, cell.ch)
  end
  if openLink then
    table.insert(parts, OSC8_CLOSE)
  end
  if lastKey ~= DEFAULT_STYLE_KEY then
    table.insert(parts, "\27[0m")
  end
  return table.concat(parts)
end

local function cellsDiffer(a, b)
  return a.ch ~= b.ch or terminalColor.key(a.fg) ~= terminalColor.key(b.fg)
    or terminalColor.key(a.bg) ~= terminalColor.key(b.bg) or a.bold ~= b.bold
    or a.dim ~= b.dim or a.italic ~= b.italic or a.underline ~= b.underline
    or a.strikethrough ~= b.strikethrough or a.inverse ~= b.inverse or a.href ~= b.href
end

-- ===================== Hyperlink capability =====================
-- OSC 8 support does NOT correlate with color capability -- a terminal
-- that reports COLORTERM=truecolor can be running inside a multiplexer or
-- CI log viewer with zero OSC 8 support, and vice versa -- so this is
-- resolved completely independently of `_colorCapability`/
-- `terminalColor.capability` above, never derived from it (see
-- host.setHyperlinkCapability's own doc comment, and Task 4's "Capability"
-- design note this module's callers were built against).
--
-- The default MUST be safe: a terminal not affirmatively known to support
-- OSC 8 gets plain visible text, never raw `]8;;...` escape bytes that
-- would show up as garbage. This mirrors the real-world practice of
-- terminal-hyperlink libraries like npm's `supports-hyperlinks` --
-- conservative allow-list of known-good terminals/multiplexer wrappers,
-- everything else defaults to off.
local KNOWN_HYPERLINK_TERM_PROGRAMS = {
  ["iterm.app"] = true, -- iTerm2, the terminal OSC 8 hyperlinks originated on
  wezterm = true,
  vscode = true, -- VS Code's integrated terminal
  hyper = true,
  tabby = true,
  rio = true,
}

--- `TERM`/`TERM_PROGRAM`/`NO_COLOR` are the same env-convention family
--- `terminalColor.capability("auto")` above is documented to use for
--- color -- but note that module's own `term_capability` never actually
--- reads `NO_COLOR` (see this file's own doc comment header: "check what
--- the repo already does for color before inventing something new" turned
--- up that this repo's existing color auto-detection has never respected
--- NO_COLOR either, a pre-existing gap, not something this function
--- should silently inherit). `NO_COLOR` (https://no-color.org) asks a
--- program to skip ALL non-essential visual embellishment, not only SGR
--- color -- most real terminal-hyperlink libraries (e.g. `supports-
--- hyperlinks`) treat it as an opt-out for OSC 8 too, so this function
--- honors it even though the sibling color function does not.
--- @param getenv? fun(name: string): string|nil Injected for testing; the
--- environment cannot be mutated from inside a Lua process, so without this
--- seam the detection rules below could only be exercised by shelling out,
--- and in practice would not be tested at all. Defaults to os.getenv.
local function autoHyperlinkCapability(getenv)
  local env = getenv or os.getenv
  if env("NO_COLOR") then return false end
  -- Explicit override, the convention `supports-hyperlinks` and friends use.
  -- Needed because no heuristic can cover every terminal, and a user who
  -- knows their terminal should not have to argue with one.
  local force = env("FORCE_HYPERLINK")
  if force and force ~= "" and force ~= "0" then return true end
  local term = (env("TERM") or ""):lower()
  if term == "" or term == "dumb" then return false end
  local termProgram = (env("TERM_PROGRAM") or ""):lower()
  if KNOWN_HYPERLINK_TERM_PROGRAMS[termProgram] then return true end
  if term:find("kitty", 1, true) or term:find("wezterm", 1, true) or term:find("alacritty", 1, true) then
    return true
  end
  if env("WT_SESSION") then return true end -- Windows Terminal
  if env("VTE_VERSION") then return true end -- GNOME Terminal and other VTE-based terminals >= 0.50
  -- 24-bit color and OSC 8 arrived in the same generation of terminals, so
  -- COLORTERM is a good proxy for "modern enough to handle, or silently
  -- ignore, an OSC 8 sequence".
  --
  -- This case is not theoretical padding: the allowlist above returns FALSE
  -- for a very ordinary real setup -- tmux (which reports TERM as
  -- xterm-256color under a common default-terminal setting, and leaves
  -- TERM_PROGRAM unset so the outer terminal's identity is lost) in front of a
  -- modern emulator. Links were silently dropped there while every visible
  -- signal said the terminal was capable. Under tmux specifically the
  -- forwarding is real: tmux has passed OSC 8 through since 3.4.
  local colorterm = (env("COLORTERM") or ""):lower()
  if colorterm == "truecolor" or colorterm == "24bit" then return true end
  return false
end

--- Exposed ONLY so the detection rules above can be exercised with a fake
--- environment. Not part of the public host API; nothing in the package calls
--- it, and it takes the env getter precisely because a Lua process cannot
--- mutate its own environment to test the real one.
--- @param getenv fun(name: string): string|nil
--- @return boolean
function M.__auto_hyperlink_capability_for_tests(getenv)
  return autoHyperlinkCapability(getenv)
end

local function hyperlinkCapability(value)
  if value == true or value == false then return value end
  if value ~= nil and value ~= "auto" then
    error("hydronium_ink.host.terminal: unsupported hyperlink capability '" .. tostring(value) .. "' (expected true, false, or \"auto\")", 3)
  end
  return autoHyperlinkCapability()
end

-- ===================== Host =====================

--- @param writeFn function|nil  Byte-string sink, defaults to io.write.
---   Injectable specifically so tests (and anything else that wants
---   deterministic, non-terminal capture) can pass a Lua-side collector
---   instead of writing to real stdout -- the same seam
---   hydronium.host.dom uses for its __dom_* bridge functions, applied
---   here to the one function this host actually needs from its
---   environment.
function M.createTerminalHost(writeFn)
  writeFn = writeFn or io.write

  local host = {
    _colorCapability = terminalColor.capability("auto"),
    -- See hydronium_ink.color's own doc comment for how this differs from
    -- `_colorCapability` above: this is the superset (adds "none") used
    -- only to resolve `ink.byProfile`/`ink.adaptive` prop values, never to
    -- pick the ANSI encoding depth a resolved color is quantized to.
    _colorProfile = terminalColor.profile("auto"),
    _hyperlinkCapability = autoHyperlinkCapability(),
    -- Real terminal cursors start visible; see host.setCursorVisible's own
    -- doc comment for what this actually gates (paint()'s own transient
    -- hide-during-redraw, NOT the app-facing useCursor position/visibility
    -- mechanism, which lives entirely in session.lua/render.lua and is
    -- unaware of this field except by informing it -- see there).
    _cursorVisible = true,
  }

  local root = {
    id = 0, type = "root", tag = "ROOT", props = {}, children = {}, parent = nil,
    _firstChild = nil, _lastChild = nil, -- see this file's own "Sibling list" section
  }

  function host.getRoot()
    return root
  end

  --- Selects the ANSI color target. "auto" uses conventional TERM/
  --- COLORTERM hints; callers can force ansi16, ansi256, or truecolor.
  function host.setColorCapability(capability)
    local resolved = terminalColor.capability(capability)
    if resolved ~= host._colorCapability then
      host._colorCapability = resolved
      host.invalidate()
    end
  end

  --- Selects the color PROFILE (see hydronium_ink.color's own doc comment
  --- and this file's `_colorProfile` field above) used to resolve
  --- `ink.byProfile`/`ink.adaptive` prop values -- "auto"/nil re-detects
  --- from the environment (NO_COLOR/FORCE_COLOR), same as
  --- `setColorCapability("auto")` does for capability. `host.invalidate()`
  --- alone is not enough here (unlike setColorCapability, whose
  --- quantization runs fresh every paint() from `host._colorCapability`
  --- with nothing cached): a Text node's OWN resolved style is cached
  --- across paints (see buildYogaTree's `isProfileStale` check), so this
  --- also has to actually change `host._colorProfile` before the next
  --- paint() runs, which the `currentColorProfile` upvalue it feeds is
  --- set from at the top of every paint() call.
  function host.setColorProfile(profile)
    local resolved = terminalColor.profile(profile)
    if resolved ~= host._colorProfile then
      host._colorProfile = resolved
      host.invalidate()
    end
  end

  --- Selects whether OSC 8 hyperlinks (`<Text href>`, see
  --- hydronium_ink/init.lua's HydroniumInkTextProps) are emitted at all.
  --- `true`/`false` force it; `"auto"`/`nil` resolves it from
  --- NO_COLOR/TERM/TERM_PROGRAM the same way a real terminal-hyperlink
  --- library would (see this file's own "Hyperlink capability" section
  --- above for exactly what "auto" checks and why it is NOT the same gate
  --- setColorCapability uses). A terminal not affirmatively known to
  --- support OSC 8 renders `href` text as plain, unlinked text -- see
  --- encodeRun's own doc comment for exactly where that degradation
  --- happens.
  function host.setHyperlinkCapability(capability)
    local resolved = hyperlinkCapability(capability)
    if resolved ~= host._hyperlinkCapability then
      host._hyperlinkCapability = resolved
      host.invalidate()
    end
  end

  --- Tells this host whether the terminal's cursor is CURRENTLY meant to
  --- be visible, so a changed host.paint() knows whether to leave it
  --- hidden or show it again after its own transient hide-during-redraw
  --- (see paint()'s own doc comment on the flicker this prevents, and why
  --- unconditionally re-showing would be wrong).
  ---
  --- This does NOT itself write anything -- hydronium_ink.hooks.useCursor
  --- (via session.lua's context.setCursorPosition) is what actually shows/
  --- hides the real cursor and moves it to an app-requested position, by
  --- writing `\27[?25l`/`\27[?25h` directly through render.lua's onCursor
  --- callback, entirely independent of this host's own diff/paint
  --- pipeline (there is no "cursor" cell in the character grid, same as
  --- the reason `host.paint()`'s own cursor-PARK sequence at the end of a
  --- changed paint only ever moves the cursor, never touches visibility,
  --- and always lands below the frame rather than at any app-requested
  --- position -- see hooks.lua's useCursor doc comment's own "STATED
  --- LIMITATION" for that pre-existing, unrelated gap). This setter only
  --- lets paint() learn what that OUTSIDE mechanism last decided, so its
  --- own hide/show wrapping can restore the same steady state rather than
  --- always ending on "visible" -- session.lua calls this every time
  --- context.setCursorPosition does, immediately alongside it.
  function host.setCursorVisible(visible)
    host._cursorVisible = visible and true or false
  end

  --- Tells this host the real terminal size, so host.paint() constrains
  --- the root Yoga node to it instead of auto-sizing to content (see
  --- YG_UNDEFINED's own doc comment). `columns`/`rows` of 0 or nil clear
  --- the constraint, going back to auto-sizing -- render.lua does this
  --- when `tty_ffi.getWindowSize()` isn't available (a non-interactive/
  --- piped run). Does not itself trigger a repaint; call host.invalidate()
  --- too (render.lua's resize-poll loop does) so the next flush() actually
  --- picks up the new size with a full redraw rather than diffing against
  --- a previous frame of a different shape.
  function host.setSize(columns, rows)
    if columns and columns > 0 and rows and rows > 0 then
      host._cols, host._rows = columns, rows
    else
      host._cols, host._rows = nil, nil
    end
  end

  function host.createInstance(tag, props)
    -- The Reconciler always hands this a plain string (unwrapTag already
    -- stripped the INTRINSIC descriptor) -- this defensive branch only
    -- matters if this host is ever driven directly, bypassing the
    -- Reconciler, exactly like host/test.lua's own tag handling.
    local tagStr = tag
    if type(tag) == "table" then
      tagStr = tag.tag or tostring(tag)
    end

    local copiedProps = {}
    local src = rawProps(props)
    for k, v in pairs(src) do
      copiedProps[k] = v
    end

    return {
      id = nextNodeId(),
      type = "element",
      tag = tostring(tagStr),
      props = copiedProps,
      children = {}, -- cached array, see childrenArray() -- correctly "0 children" until something appends
      parent = nil,
      -- Sibling-list fields (see this file's own "Sibling list" section):
      -- `_firstChild`/`_lastChild` because this node can itself be a
      -- parent; `_prevSibling`/`_nextSibling` because it can itself be a
      -- child of another element/root node.
      _firstChild = nil, _lastChild = nil, _prevSibling = nil, _nextSibling = nil,
    }
  end

  function host.createTextInstance(text)
    return {
      id = nextNodeId(),
      type = "text",
      text = tostring(text or ""),
      parent = nil,
      -- A text node is never a parent (no `_firstChild`/`_lastChild` --
      -- childrenArray() on one still works, see its own doc comment,
      -- since a missing `_firstChild` field just reads as nil), but it
      -- CAN be a child, so it still needs sibling links.
      _prevSibling = nil, _nextSibling = nil,
    }
  end

  --- O(1): splices `child` onto the tail of `parent`'s sibling linked
  --- list directly via `parent._lastChild`, rather than scanning/shifting
  --- a plain array (see this file's own "Sibling list" section for why
  --- this specific call, invoked once per child on EVERY re-render by
  --- core/reconciler.lua's reconcileChildren regardless of whether
  --- anything actually moved, used to be this host's O(N^2) hot spot).
  function host.appendChild(parent, child)
    if not parent or not child then return end
    detachFromParent(child) -- marks the OLD parent dirty too, if this is a move; O(1), see its own doc comment
    child.parent = parent
    child._prevSibling, child._nextSibling = parent._lastChild, nil
    if parent._lastChild then
      parent._lastChild._nextSibling = child
    else
      parent._firstChild = child
    end
    parent._lastChild = child
    parent.children = nil -- invalidate the array cache -- see childrenArray()
    markChildrenDirty(parent)
    host._dirty = true
  end

  --- O(1): splices `child` in immediately before `beforeChild` via direct
  --- node references (`beforeChild._prevSibling`), rather than scanning a
  --- plain array for `beforeChild`'s index first (the OLD implementation's
  --- own separate O(siblings) cost, on top of the shift `table.insert(t,
  --- i, ...)` in the middle of an array also has) -- see this file's own
  --- "Sibling list" section.
  function host.insertBefore(parent, child, beforeChild)
    if not parent or not child then return end
    detachFromParent(child) -- marks the OLD parent dirty too, if this is a move
    child.parent = parent

    if beforeChild and beforeChild.parent == parent then
      local prev = beforeChild._prevSibling
      child._prevSibling, child._nextSibling = prev, beforeChild
      beforeChild._prevSibling = child
      if prev then prev._nextSibling = child else parent._firstChild = child end
    else
      -- No valid beforeChild belonging to this parent -- append at the
      -- end, matching the original array-based implementation's own
      -- fallback ("if not inserted then table.insert(parent.children,
      -- child) end").
      child._prevSibling, child._nextSibling = parent._lastChild, nil
      if parent._lastChild then parent._lastChild._nextSibling = child else parent._firstChild = child end
      parent._lastChild = child
    end
    parent.children = nil -- invalidate the array cache -- see childrenArray()
    markChildrenDirty(parent)
    host._dirty = true
  end

  --- O(1): unlinks `child` from the sibling list directly, rather than
  --- scanning/shifting a plain array -- see this file's own "Sibling
  --- list" section.
  function host.removeChild(parent, child)
    if not parent or not child then return end
    if child.parent == parent then
      local prev, nextSibling = child._prevSibling, child._nextSibling
      if prev then prev._nextSibling = nextSibling else parent._firstChild = nextSibling end
      if nextSibling then nextSibling._prevSibling = prev else parent._lastChild = prev end
      child._prevSibling, child._nextSibling = nil, nil
      child.parent = nil
      parent.children = nil -- invalidate the array cache -- see childrenArray()
    end
    markChildrenDirty(parent)
    -- Real, permanent removal (unlike a move through detachFromParent) --
    -- see freeYogaSubtree's own doc comment -- so this is the one place
    -- safe to actually free child's (and its subtree's) persistent Yoga
    -- nodes rather than just letting them go stale.
    freeYogaSubtree(child)
    host._dirty = true
  end

  function host.commitUpdate(node, oldProps, newProps)
    if not node then return end
    local updated = {}
    local src = rawProps(newProps)
    for k, v in pairs(src) do
      updated[k] = v
    end
    node.props = updated
    markStyleDirty(node)
    host._dirty = true
  end

  function host.commitTextUpdate(node, oldText, newText)
    if not node then return end
    node.text = tostring(newText or "")
    markStyleDirty(node)
    host._dirty = true
  end

  --- Recomputes layout for the whole tree from `root` down, diffs the
  --- resulting character grid against the previous paint's grid, and
  --- writes only the minimal ANSI needed to fix the difference (a full
  --- clear+redraw on the very first paint, or whenever the frame's
  --- overall width/height changes since there is then no previous frame
  --- of a compatible shape to diff against). See this module's own doc
  --- comment ("REPAINT STRATEGY", "DIFFING").
  --- Not part of the Reconciler's Host contract -- exposed the same way
  --- host/dom.lua exposes hydrateProps/mismatchLog beyond the 7 required
  --- methods. ALWAYS repaints unconditionally when called, regardless of
  --- the dirty flag -- host.flush() (below) is the dirty-flag-gated
  --- entry point every normal caller should use; this is exposed
  --- separately for a test/tool that genuinely wants to force a repaint
  --- right now.
  function host.paint()
    local availW, availH = host._cols or YG_UNDEFINED, host._rows or YG_UNDEFINED
    -- Set once per paint(), read by every plain module-level function this
    -- pass touches (buildYogaTree/textStyleOf/paintNode/resolveBorderEdge
    -- via `resolveStyleValue`/`currentColorProfile` above) -- see that
    -- upvalue's own doc comment for why this is a shared module local
    -- rather than a parameter threaded through all of them.
    currentColorProfile = host._colorProfile

    local rootYoga = buildYogaTree(root)
    rootYoga:calculateLayout(availW, availH)
    resolvePositions(root, 1, 1) -- 1-indexed frame coordinates, see resolvePositions()

    -- Two-pass reflow for Text nodes using wrap="wrap"/"hard" with no
    -- explicit width prop (buildYogaTree flagged them via
    -- node._pendingWrap instead of wrapping immediately, since it had no
    -- width to wrap against yet). Pass 1, above, measured each at its
    -- natural (unwrapped) width so Yoga's own flex/stretch could resolve
    -- its real available width; collect that now, rewrap against it, and
    -- rerun build+layout once more with the wrapped lines pinned to that
    -- resolved width (node._prewrapWidth/_prewrapLines -- see
    -- buildYogaTree's Text branch, which always recomputes this specific
    -- case regardless of dirty flags). Pinning the width (rather than
    -- re-measuring it from the now-shorter wrapped content) is what keeps
    -- this to exactly two passes: pass 2 asserts the same width Yoga
    -- already computed in pass 1, so it resolves identically again.
    -- Every Yoga node involved is the same persistent one both passes --
    -- rerunning buildYogaTree a second time here just re-patches style on
    -- whatever's actually dirty (which, for a pending-wrap Text, is
    -- unconditional), it does not rebuild or free anything.
    local pendingWrap = {}
    local function collectPendingWrap(n)
      if n._pendingWrap then table.insert(pendingWrap, n) end
      if n._layoutKind == "box" then
        local kids = childrenArray(n)
        for i = 1, #kids do collectPendingWrap(kids[i]) end
      end
    end
    collectPendingWrap(root)

    if #pendingWrap > 0 then
      for _, n in ipairs(pendingWrap) do
        local resolvedWidth = math.max(n._layout.clientW or n._layout.w, 0)
        local reflowed = {}
        if TRUNCATE_MODES[n._pendingWrap] then
          -- Truncation keeps the line count fixed, so pass 2 only ever
          -- narrows this node -- it can never push it taller and disturb
          -- the layout Yoga just resolved.
          for i, line in ipairs(n._layoutLines) do
            reflowed[i] = truncateLine(line, resolvedWidth, n._pendingWrap)
          end
        else
          for _, line in ipairs(n._layoutLines) do
            for _, wline in ipairs(wrapLine(line, resolvedWidth, n._pendingWrap == "hard")) do
              table.insert(reflowed, wline)
            end
          end
        end
        n._prewrapWidth = resolvedWidth
        n._prewrapLines = reflowed
      end

      rootYoga = buildYogaTree(root)
      rootYoga:calculateLayout(availW, availH)
      resolvePositions(root, 1, 1)

      for _, n in ipairs(pendingWrap) do
        n._prewrapWidth = nil
        n._prewrapLines = nil
      end
    end

    local rootLayout = root._layout
    local w, h = math.max(rootLayout.w, 0), math.max(rootLayout.h, 0)
    local frame = newFrame(w, h)
    paintNode(root, frame)

    local buf = {}
    local prev = host._lastFrame
    -- Tracks whether this paint actually changed anything visible, so a
    -- genuinely no-op paint (the Reconciler's own reconcileChildren
    -- unconditionally re-runs commitUpdate and re-appends every child
    -- "to ensure sibling order" even when nothing moved -- see
    -- core/reconciler.lua -- which drives this host's paint() far more
    -- often than the visible frame actually changes) writes NOTHING at
    -- all, not even the cursor-park sequence below. Without this guard
    -- every one of those structurally-harmless reconciler calls would
    -- still emit bytes, which is real but misleading "diffing" -- it
    -- would technically never touch a changed cell, but it would still
    -- spam the output stream on every commit.
    local changed = false

    if not prev or prev.w ~= w or prev.h ~= h then
      changed = true
      table.insert(buf, "\27[2J\27[H")
      for y = 1, h do
        table.insert(buf, "\27[" .. y .. ";1H\27[K")
        table.insert(buf, encodeRun(frame.rows[y], 1, w, host._colorCapability, host._hyperlinkCapability))
      end
    else
      for y = 1, h do
        local newRow, oldRow = frame.rows[y], prev.rows[y]
        local x = 1
        while x <= w do
          if cellsDiffer(newRow[x], oldRow[x]) then
            changed = true
            local runStart = x
            while x <= w and cellsDiffer(newRow[x], oldRow[x]) do
              x = x + 1
            end
            table.insert(buf, "\27[" .. y .. ";" .. runStart .. "H")
            table.insert(buf, encodeRun(newRow, runStart, x - 1, host._colorCapability, host._hyperlinkCapability))
          else
            x = x + 1
          end
        end
      end
    end

    host._lastFrame = frame

    if changed then
      -- Park the cursor just below the painted frame so whatever the
      -- surrounding terminal session does next (a shell prompt, program
      -- exit, ^C) doesn't land inside the rendered picture -- ordinary
      -- real-Ink behavior too, not specific to this implementation.
      table.insert(buf, "\27[" .. (h + 1) .. ";1H\27[0m")

      -- CURSOR HIDE/SHOW (flicker fix): without this, the real terminal
      -- cursor visibly darts to every changed run's position as each
      -- `\27[<row>;<col>H` move lands, for the entire duration of this
      -- redraw, before finally landing on the park sequence above -- on a
      -- frame with many small scattered changed runs (the common case for
      -- a heavy-refresh section) this is the single most visible "flicker"
      -- this host produces. Hiding for the duration of the write and
      -- restoring after removes it, at the cost of the terminal not
      -- knowing exactly where a real hardware/IME cursor should sit while
      -- the redraw is in flight -- an acceptable trade since this host
      -- already has no notion of showing the true cursor mid-redraw
      -- anyway (see the park sequence just above, which relocates it
      -- unconditionally on every changed paint regardless of this fix).
      --
      -- MUST restore to `host._cursorVisible`, NOT unconditionally show:
      -- an app that called `useCursor().setCursorPosition(nil)` to
      -- explicitly hide the cursor (see hooks.lua's UseCursorResult doc
      -- comment) has that state entirely outside this host's paint
      -- pipeline -- session.lua informs this host of it via
      -- host.setCursorVisible so this restore can put things back exactly
      -- how they were, rather than always ending on "visible" and
      -- silently overriding an app's explicit hide the next time anything
      -- repaints. This does NOT restore the app's requested cursor
      -- POSITION (only visibility) -- the park sequence above already
      -- unconditionally relocates the cursor below the frame regardless
      -- of this fix, which is the same pre-existing, already-documented
      -- gap hooks.lua's useCursor doc comment calls out ("every repaint
      -- that actually changes something re-parks the cursor below the
      -- frame... a persistent custom position needs re-calling this").
      --
      -- Wrapped OUTSIDE that in DEC 2026 synchronized-output brackets
      -- (`\27[?2026h`/`l`): a single write() to a tty is not guaranteed
      -- atomic, so without this a large buffer (worst case: the full-
      -- redraw branch above, on first paint/resize/invalidate) can be
      -- split across the terminal's own reads and render as a torn,
      -- partial frame. Emitted UNCONDITIONALLY, with no capability gate,
      -- unlike setColorCapability/setHyperlinkCapability above -- DEC
      -- private modes are specified so that a terminal not implementing a
      -- given mode number silently ignores the DECSET/DECRST for it (no
      -- visible side effect, unlike an unrecognized OSC, which some real
      -- terminals mishandle by echoing raw bytes -- see this file's own
      -- "Hyperlink capability" section for why OSC 8 needed a gate and
      -- this doesn't). This repo already relies on that exact convention
      -- for other DEC private modes without gating them (bracketed paste
      -- `\27[?2004h` in render.lua's M.render, alternate screen
      -- `\27[?1049h`/`l` via onAltScreen) -- mode 2026 gets the same
      -- treatment, not a new policy invented for it.
      local body = "\27[?25l" .. table.concat(buf)
      if host._cursorVisible then body = body .. "\27[?25h" end
      writeFn("\27[?2026h" .. body .. "\27[?2026l")
    end
  end

  --- The entry point normal callers use: repaints ONLY if something
  --- mutated the tree since the last flush (host._dirty, set by the 5
  --- mutating Host-contract methods above), then clears the flag. Call
  --- this after reconciler:mount()/:reconcile() returns, or after
  --- scheduler.flush() returns (e.g. right after a signal setter) -- see
  --- this module's own "REPAINT STRATEGY" doc comment for why no
  --- automatic commit-end hook exists to call this for you. A flush with
  --- nothing dirty is a no-op (no measure/paint/write work at all, not
  --- even a diff against an unchanged frame).
  function host.flush()
    if not host._dirty then return end
    host._dirty = false
    host.paint()
  end

  --- Not part of the Host contract; a debugging/testing convenience
  --- returning the character+style grid from the most recent paint (or
  --- nil before the first one).
  function host.getLastFrame()
    return host._lastFrame
  end

  --- Forgets the previous frame and marks the tree dirty, so the next
  --- flush() does a full clear+redraw instead of diffing against a frame
  --- the terminal is no longer showing.
  ---
  --- Needed whenever something OUTSIDE this host changes what is actually
  --- on screen, which the diff in paint() cannot know about: the real case
  --- is render.lua switching into or out of the terminal's alternate
  --- screen buffer (`\27[?1049h`/`l`), which swaps in a screen sharing
  --- none of the previous frame's cells -- without this, the next paint
  --- would emit only the handful of cells that changed in the Lua-side
  --- grid and leave the rest of the frame missing. Also the honest escape
  --- hatch for anything else that writes over this host's output (an
  --- external `clear`, a subprocess printing to the same terminal).
  function host.invalidate()
    host._lastFrame = nil
    host._dirty = true
  end

  return host
end

return M
