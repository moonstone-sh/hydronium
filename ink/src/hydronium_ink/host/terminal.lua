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

  KNOWN REMAINING SCALING COST, discovered profiling the persistence work
  above rather than assumed: detachFromParent's `table.remove(siblings, i)`
  is O(remaining siblings), and core/reconciler.lua's own reconcileChildren
  calls appendChild for EVERY child on EVERY re-render "to ensure sibling
  order" (see this file's own "REPAINT STRATEGY" doc comment above) even
  when the order didn't change -- so a Box with N children re-renders in
  O(N^2), dominated by table.remove, not by anything Yoga-related. Sampling
  profiler evidence: for N=2000 siblings with one child's text changing,
  table.remove accounted for over half of all samples taken during a
  single update, and the persistent-Yoga-tree work above measured as
  functionally free by comparison (calculateLayout over 2000 already-built
  nodes: ~1 microsecond; the OLD full-rebuild code's 2000 newNode+free
  calls: ~1.5ms -- both dwarfed by table.remove's cost at this N). Fixing
  this needs parent.children to stop being a plain shifting array (an
  intrusive doubly-linked list, or similar O(1)-move structure), which
  ripples through every place in this file that walks it by index --
  a separate, larger change not attempted here.

  LuaJIT-only: see hydronium_ink/init.lua's doc comment for why (Yoga is
  bound via LuaJIT's `ffi`, which plain PUC Lua has no equivalent of).
--]]

local Yoga = require("hydronium_ink.yoga_ffi")
local textMetrics = require("hydronium_ink.text_metrics")
local terminalColor = require("hydronium_ink.color")

local M = {}

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

--- Detaches `child` from whatever parent it currently has (a no-op if
--- none). Used by appendChild/insertBefore to handle a MOVE (Yoga-owning
--- ancestors on both the old and new side each need their child list
--- resynced) as well as a fresh insert (nothing to detach from yet).
local function detachFromParent(child)
  if child.parent and child.parent.children then
    local siblings = child.parent.children
    for i = 1, #siblings do
      if siblings[i] == child then
        table.remove(siblings, i)
        break
      end
    end
    markChildrenDirty(child.parent)
    child.parent = nil
  end
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
  for i = 1, #(node.children or {}) do
    freeYogaSubtree(node.children[i])
  end
end

-- ===================== Layout =====================

local function textStyleOf(props, inherited)
  inherited = inherited or {}
  local style = {
    fg = inherited.fg, bg = inherited.bg, bold = inherited.bold,
    dim = inherited.dim, italic = inherited.italic, underline = inherited.underline,
    strikethrough = inherited.strikethrough, inverse = inherited.inverse,
  }
  if props then
    if props.color ~= nil then style.fg = terminalColor.resolve(props.color) end
    if props.backgroundColor ~= nil then style.bg = terminalColor.resolve(props.backgroundColor) end
    if props.bold ~= nil then style.bold = props.bold and true or false end
    if props.dimColor ~= nil then style.dim = props.dimColor and true or false end
    if props.italic ~= nil then style.italic = props.italic and true or false end
    if props.underline ~= nil then style.underline = props.underline and true or false end
    if props.strikethrough ~= nil then style.strikethrough = props.strikethrough and true or false end
    if props.inverse ~= nil then style.inverse = props.inverse and true or false end
  end
  return style
end

-- Parses the small, style-only SGR vocabulary this host can paint back into
-- cell runs. Transform receives plain text, but its result may use ordinary
-- ANSI styling (as gradient/chalk-style helpers do) without leaking escape
-- bytes into the terminal grid.
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
    for i = 1, #n.children do
      local c = n.children[i]
      if c.type == "text" then
        table.insert(current, {
          text = c.text, fg = localStyle.fg, bg = localStyle.bg, bold = localStyle.bold,
          dim = localStyle.dim, italic = localStyle.italic, underline = localStyle.underline,
          strikethrough = localStyle.strikethrough, inverse = localStyle.inverse,
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
-- (real reflow, see WRAP_MODES/wrapLine below), truncation only ever
-- applies when `Text` has its own explicit `width` prop: it cuts the text
-- to fit AFTER that width is already known, with no need to learn one
-- from Yoga's own layout pass first. A `Text` whose width is merely
-- inherited from a container's own layout is NOT truncated (it would
-- need the same width-resolved-by-Yoga two-pass machinery `wrap` uses).
local TRUNCATE_MODES = {
  truncate = true, ["truncate-start"] = true, ["truncate-middle"] = true, ["truncate-end"] = true,
}

local function copyRunWith(run, text)
  return {
    text = text, fg = run.fg, bg = run.bg, bold = run.bold, dim = run.dim,
    italic = run.italic, underline = run.underline, strikethrough = run.strikethrough,
    inverse = run.inverse,
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
    -- to free again immediately below. Its `children` field, though, is
    -- the REAL `node.children` -- the actual persistent host nodes,
    -- reused across paints and potentially still holding a `_yoga` from
    -- a PRIOR Transform call. `removeAllChildren()` before freeing
    -- `isolatedRootYg` detaches them cleanly without touching their own
    -- persistent Yoga nodes at all, so they stay valid and reusable for
    -- next time (or for freeYogaSubtree, whenever they're genuinely
    -- unmounted via host.removeChild -- never triggered from here).
    local anonymousRoot = {
      id = nextNodeId(), type = "root", tag = "TransformRoot",
      props = {}, children = node.children, parent = nil,
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
    local isWrapNoWidth = WRAP_MODES[props.wrap] and not props.width

    if isNew or node._styleDirty or isWrapNoWidth then
      local lines = collectTextLines(node, textStyleOf(props))
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
      elseif node._prewrapWidth and WRAP_MODES[props.wrap] then
        -- Pass 2 of the two-pass reflow host.paint() runs for a wrap mode
        -- with no explicit width (see its own doc comment): use the lines
        -- already wrapped there, against pass 1's real resolved width.
        lines = node._prewrapLines
      elseif WRAP_MODES[props.wrap] then
        -- Pass 1: no explicit width yet, so there is nothing to wrap
        -- against -- give Yoga the natural (unwrapped) width so its own
        -- flex/stretch can resolve this node's real available width, and
        -- flag it for host.paint() to rewrap and rerun layout once more.
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
      elseif node._prewrapWidth and WRAP_MODES[props.wrap] then
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
  for i = 1, #node.children do
    local childYg = buildYogaTree(node.children[i])
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
    for i = 1, #node.children do
      resolvePositions(node.children[i], x, y)
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
      }
    end
    frame.rows[r] = row
  end
  return frame
end

--- @param style table|nil {fg, bg, bold, dim, italic, underline, strikethrough, inverse}
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
    inverse = style.inverse or false,
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
  return color and terminalColor.resolve(color), dim and true or false
end

paintNode = function(node, frame, clip, offsetX, offsetY)
  local layout = node._layout
  offsetX, offsetY = offsetX or 0, offsetY or 0

  if layout.kind == "box" then
    local props = node.props or {}
    local x1, y1 = layout.x + offsetX, layout.y + offsetY
    local x2, y2 = layout.x + layout.w - 1, layout.y + layout.h - 1
    local bg = props.backgroundColor and terminalColor.resolve(props.backgroundColor)

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
        local baseFg = props.borderColor and terminalColor.resolve(props.borderColor)
        local baseDim = props.borderDimColor and true or false
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
      for i = 1, #node.children do
        local childLayout = node.children[i]._layout
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

    for i = 1, #node.children do
      paintNode(node.children[i], frame, childClip, childOffsetX, childOffsetY)
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

local function styleKey(cell)
  return terminalColor.key(cell.fg) .. ":" .. terminalColor.key(cell.bg) .. ":"
    .. (cell.bold and 1 or 0) .. ":" .. (cell.dim and 1 or 0) .. ":"
    .. (cell.italic and 1 or 0) .. ":" .. (cell.underline and 1 or 0) .. ":"
    .. (cell.strikethrough and 1 or 0) .. ":" .. (cell.inverse and 1 or 0)
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

--- Encodes columns [c1..c2] of `row` as a byte string, switching SGR
--- state only when the active style actually changes cell-to-cell (real
--- style-run coalescing, not a fresh reset+code pair on every
--- character) and leaving the terminal in the default (reset) style
--- when the run ends on anything but the default, so a subsequent
--- unrelated write (a shell prompt, a later diff run) never inherits a
--- stray color.
local function encodeRun(row, c1, c2, colorCapability)
  local parts = {}
  local lastKey = nil
  for x = c1, c2 do
    local cell = row[x]
    local key = styleKey(cell)
    if key ~= lastKey then
      table.insert(parts, sgrFor(cell, colorCapability))
      lastKey = key
    end
    table.insert(parts, cell.ch)
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
    or a.strikethrough ~= b.strikethrough or a.inverse ~= b.inverse
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

  local host = { _colorCapability = terminalColor.capability("auto") }

  local root = { id = 0, type = "root", tag = "ROOT", props = {}, children = {}, parent = nil }

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
      children = {},
      parent = nil,
    }
  end

  function host.createTextInstance(text)
    return {
      id = nextNodeId(),
      type = "text",
      text = tostring(text or ""),
      parent = nil,
    }
  end

  function host.appendChild(parent, child)
    if not parent or not child then return end
    detachFromParent(child) -- marks the OLD parent dirty too, if this is a move
    child.parent = parent
    table.insert(parent.children, child)
    markChildrenDirty(parent)
    host._dirty = true
  end

  function host.insertBefore(parent, child, beforeChild)
    if not parent or not child then return end
    detachFromParent(child) -- marks the OLD parent dirty too, if this is a move
    child.parent = parent

    local inserted = false
    if beforeChild and parent.children then
      for i = 1, #parent.children do
        if parent.children[i] == beforeChild then
          table.insert(parent.children, i, child)
          inserted = true
          break
        end
      end
    end
    if not inserted then
      table.insert(parent.children, child)
    end
    markChildrenDirty(parent)
    host._dirty = true
  end

  function host.removeChild(parent, child)
    if not parent or not child then return end
    if parent.children then
      for i = 1, #parent.children do
        if parent.children[i] == child then
          table.remove(parent.children, i)
          child.parent = nil
          break
        end
      end
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
        for i = 1, #n.children do collectPendingWrap(n.children[i]) end
      end
    end
    collectPendingWrap(root)

    if #pendingWrap > 0 then
      for _, n in ipairs(pendingWrap) do
        local resolvedWidth = math.max(n._layout.clientW or n._layout.w, 0)
        local wrapped = {}
        for _, line in ipairs(n._layoutLines) do
          for _, wline in ipairs(wrapLine(line, resolvedWidth, n._pendingWrap == "hard")) do
            table.insert(wrapped, wline)
          end
        end
        n._prewrapWidth = resolvedWidth
        n._prewrapLines = wrapped
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
        table.insert(buf, encodeRun(frame.rows[y], 1, w, host._colorCapability))
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
            table.insert(buf, encodeRun(newRow, runStart, x - 1, host._colorCapability))
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
      writeFn(table.concat(buf))
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
