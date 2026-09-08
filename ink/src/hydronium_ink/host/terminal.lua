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
  now work, which the block-stacker this replaced never could. A fresh
  Yoga node tree is built and freed on every paint() call (mirroring this
  module's existing "recompute layout from scratch every paint" approach,
  not an incremental one) -- see buildYogaTree()/resolvePositions() below.
  Text measurement (collectTextLines et al.) stays this module's own
  responsibility, feeding Yoga fixed-size leaves; text wrapping remains
  out of scope. See docs/HYDRONIUM_INK_TERMINAL_HOST.md.

  LuaJIT-only: see hydronium_ink/init.lua's doc comment for why (Yoga is
  bound via LuaJIT's `ffi`, which plain PUC Lua has no equivalent of).
--]]

local Yoga = require("hydronium_ink.yoga_ffi")

local M = {}

-- Named color -> SGR digit (\27[3<n>m). "gray" deliberately occupies the
-- slot the SGR spec calls "black" (n=0): the requested named set is
-- red/green/yellow/blue/magenta/cyan/white/gray, i.e. 8 names for the 8
-- \27[3<n>m slots, and something has to take slot 0. Many real terminal
-- color schemes already render SGR 30 as a dark gray rather than pure
-- black, which is why this mapping (rather than, say, silently dropping
-- "gray" or reaching for a non-\27[3<n>m bright-black code) was chosen --
-- but on a literal black-on-black theme this WILL render as invisible
-- black, not a visible gray. Documented limitation, not a bug to chase.
local COLOR_CODES = {
  gray = 0, red = 1, green = 2, yellow = 3, blue = 4, magenta = 5, cyan = 6, white = 7,
}

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

local function detachFromParent(child)
  if child.parent and child.parent.children then
    local siblings = child.parent.children
    for i = 1, #siblings do
      if siblings[i] == child then
        table.remove(siblings, i)
        break
      end
    end
    child.parent = nil
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
    if props.color ~= nil then style.fg = COLOR_CODES[props.color] end
    if props.backgroundColor ~= nil then style.bg = COLOR_CODES[props.backgroundColor] end
    if props.bold ~= nil then style.bold = props.bold and true or false end
    if props.dimColor ~= nil then style.dim = props.dimColor and true or false end
    if props.italic ~= nil then style.italic = props.italic and true or false end
    if props.underline ~= nil then style.underline = props.underline and true or false end
    if props.strikethrough ~= nil then style.strikethrough = props.strikethrough and true or false end
    if props.inverse ~= nil then style.inverse = props.inverse and true or false end
  end
  return style
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

-- Truncation modes this module implements. `wrap = "wrap"`/`"hard"` (real
-- reflow, matching real Ink's other two documented `wrap` values) is
-- deliberately NOT implemented -- see docs/HYDRONIUM_INK_TERMINAL_HOST.md.
-- Real reflow needs to know an available width DURING Yoga's own layout
-- pass (via a Yoga "measure function" callback, YGNodeSetMeasureFunc,
-- which this module's FFI binding does not register), not after the
-- fact like these truncation modes can. Truncation only ever applies
-- here when the `Text` itself has an explicit `width` prop (added
-- specifically for this) -- unlike real Ink, a `Text` inheriting a
-- narrower width purely from its container's own layout does NOT get
-- truncated, for the same measure-function reason.
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
--- `width` cells, preserving per-run styling at the cut boundary as best
--- it can. Uses a plain ASCII "..." marker, not a real Unicode ellipsis
--- -- consistent with this module's existing byte-per-cell text model
--- (see paintNode's own per-byte `setCell` loop), which has no
--- wide-character/emoji width accounting anywhere yet; a real ellipsis
--- glyph would itself violate that same one-byte-one-cell assumption.
--- @param line table[] Array of {text, fg, bg, bold, ...} runs.
--- @param width integer
--- @param mode "truncate"|"truncate-start"|"truncate-middle"|"truncate-end"
--- @return table[] truncated line
local function truncateLine(line, width, mode)
  if width < 0 then width = 0 end
  local total = 0
  for _, run in ipairs(line) do total = total + #run.text end
  if total <= width then return line end
  if width == 0 or #line == 0 then return {} end

  local marker = ("..."):sub(1, math.min(3, width))
  local keep = math.max(width - #marker, 0)

  local function takeFromStart(n)
    local result, remaining = {}, n
    for _, run in ipairs(line) do
      if remaining <= 0 then break end
      local take = math.min(remaining, #run.text)
      table.insert(result, copyRunWith(run, run.text:sub(1, take)))
      remaining = remaining - take
    end
    return result
  end

  local function takeFromEnd(n)
    local result, remaining = {}, n
    for i = #line, 1, -1 do
      if remaining <= 0 then break end
      local run = line[i]
      local take = math.min(remaining, #run.text)
      table.insert(result, 1, copyRunWith(run, run.text:sub(#run.text - take + 1)))
      remaining = remaining - take
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

-- "Undefined" in Yoga's own sense (its C headers `#define YGUndefined
-- NAN` -- not a linkable symbol, just a NaN float): used as the root's
-- available width/height so it auto-sizes to its content, exactly like
-- the old measure()'s root-has-no-fixed-size behavior. NOT the terminal's
-- real column/row count -- this module still has no notion of that (see
-- docs/HYDRONIUM_INK_TERMINAL_HOST.md's "Layout" scope statement).
local YG_UNDEFINED = 0 / 0

-- Forward declarations: Transform's own buildYogaTree branch (below)
-- renders its children into a fully isolated sub-tree, using these same
-- functions (each real, defined later in this file) to do so -- rather
-- than duplicating the build/layout/paint pipeline a second time.
local cell
local resolvePositions
local newFrame
local paintNode
local freeYogaTree

--- Builds a real Yoga node for `node` and its whole subtree, setting
--- style from Box props (or fixed content-box sizing for text leaves),
--- and stashes it on `node._yoga` / `node._layoutKind` / `node._layoutLines`
--- (fields this module owns exclusively, like the old `node._layout` was)
--- for `resolvePositions()` below to read back after `calculateLayout()`.
--- Rebuilt from scratch on every paint(), not maintained incrementally --
--- mirrors this module's pre-Yoga "recompute layout every paint" approach;
--- the Lua-side trees involved are small enough that reallocating Yoga
--- nodes per paint is not a real cost, and it avoids having to hook Yoga
--- node lifecycle into createInstance/removeChild/etc.
local function buildYogaTree(node, yogaNodes)
  local yg = Yoga.newNode()
  yogaNodes[#yogaNodes + 1] = yg
  node._yoga = yg

  if node.type == "text" then
    node._layoutKind = "text"
    yg:setStyle({ width = #node.text, height = 1 })
    return yg
  end

  if node.type == "element" and node.tag == "Newline" then
    node._layoutKind = "newline"
    yg:setStyle({ width = 0, height = 1 })
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
    yg:setStyle({ flexGrow = 1 })
    return yg
  end

  if node.type == "element" and node.tag == "Transform" then
    -- Renders `node.children` into a fully isolated sub-tree and frame
    -- (its own Yoga nodes, built/laid out/painted/freed entirely within
    -- this branch -- not part of the outer paint()'s own yogaNodes list
    -- or its calculateLayout() pass), extracts each row as PLAIN text
    -- (see this module's own doc comment above on Transform: no ANSI
    -- re-parsing -- a transform that injects its own ANSI codes is not
    -- supported), and calls `props.transform(line, index)` on each
    -- (1-indexed, not real Ink's 0-indexed convention). The transformed
    -- strings become this node's own "transform_block" content -- from
    -- the OUTER tree's perspective, a Transform is a fixed-size leaf,
    -- exactly like a Text.
    local isolatedYogaNodes = {}
    local anonymousRoot = {
      id = nextNodeId(), type = "root", tag = "TransformRoot",
      props = {}, children = node.children, parent = nil,
    }
    local isolatedRootYg = buildYogaTree(anonymousRoot, isolatedYogaNodes)
    isolatedRootYg:calculateLayout(YG_UNDEFINED, YG_UNDEFINED)
    resolvePositions(anonymousRoot, 1, 1)

    local isolatedLayout = anonymousRoot._layout
    local iw, ih = math.max(isolatedLayout.w, 0), math.max(isolatedLayout.h, 0)
    local tempFrame = newFrame(iw, ih)
    paintNode(anonymousRoot, tempFrame)
    freeYogaTree(isolatedYogaNodes)

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
      transformedLines[i] = out
      if #out > w then w = #out end
    end

    node._layoutKind = "transform_block"
    node._layoutLines = transformedLines
    yg:setStyle({ width = w, height = math.max(#transformedLines, 1) })
    return yg
  end

  if node.type == "element" and node.tag == "Text" then
    local lines = collectTextLines(node, textStyleOf(node.props))
    local props = node.props or {}
    if props.width and TRUNCATE_MODES[props.wrap] then
      for i, line in ipairs(lines) do
        lines[i] = truncateLine(line, props.width, props.wrap)
      end
    end
    local w = 0
    for _, line in ipairs(lines) do
      local lw = 0
      for _, run in ipairs(line) do lw = lw + #run.text end
      if lw > w then w = lw end
    end
    if props.width then w = props.width end
    node._layoutKind = "text_block"
    node._layoutLines = lines
    yg:setStyle({ width = w, height = math.max(#lines, 1) })
    return yg
  end

  -- Box (tag == "Box") and the implicit root container (its `props` table
  -- is always `{}` -- see createTerminalHost below) share this same
  -- style mapping; Yoga's own flex algorithm (grow/shrink/wrap/justify/
  -- align, auto-sizing from children when width/height are unset) replaces
  -- what used to be this module's own hand-rolled block-stacking math.
  local props = node.props or {}
  node._layoutKind = "box"
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

  for i = 1, #node.children do
    local childYg = buildYogaTree(node.children[i], yogaNodes)
    yg:insertChild(childYg, i - 1) -- Yoga child indices are 0-based
  end

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
    -- Captured here (not lazily from measureElement()) because the real
    -- Yoga node is about to be freed by freeYogaTree() -- see
    -- YogaNode:getComputedLayout()'s own doc comment.
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

--- Frees every Yoga node created by `buildYogaTree()` for this paint --
--- called after resolvePositions() has read everything back, since this
--- module rebuilds the whole Yoga tree per paint rather than keeping one
--- alive across paints (see buildYogaTree()'s own doc comment).
freeYogaTree = function(yogaNodes)
  for i = 1, #yogaNodes do
    yogaNodes[i]:free()
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
---   paintNode() for a `Box` with `overflow = "hidden"` (or `"scroll"`,
---   which this module treats identically -- there is no real scrollable
---   viewport here, just the same clipping).
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
  return color and COLOR_CODES[color], dim and true or false
end

paintNode = function(node, frame, clip)
  local layout = node._layout

  if layout.kind == "box" then
    local props = node.props or {}
    local x1, y1 = layout.x, layout.y
    local x2, y2 = layout.x + layout.w - 1, layout.y + layout.h - 1
    local bg = props.backgroundColor and COLOR_CODES[props.backgroundColor]

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
        local baseFg = props.borderColor and COLOR_CODES[props.borderColor]
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

    for i = 1, #node.children do
      paintNode(node.children[i], frame, childClip)
    end
  elseif layout.kind == "text_block" then
    for i, line in ipairs(layout.lines) do
      local cx = layout.x
      local cy = layout.y + i - 1
      for _, run in ipairs(line) do
        for j = 1, #run.text do
          setCell(frame, cx, cy, run.text:sub(j, j), run, clip)
          cx = cx + 1
        end
      end
    end
  elseif layout.kind == "text" then
    -- Bare text directly under a Box (no enclosing <Text>) -- see the
    -- "text" kind's doc comment on measure() above.
    local cx = layout.x
    for j = 1, #node.text do
      setCell(frame, cx, layout.y, node.text:sub(j, j), nil, clip)
      cx = cx + 1
    end
  elseif layout.kind == "transform_block" then
    -- Plain, unstyled text -- see this node's own buildYogaTree branch
    -- and this module's Transform doc comment for why (no ANSI
    -- re-parsing of a transform's return value).
    for i, line in ipairs(layout.lines) do
      local cx = layout.x
      local cy = layout.y + i - 1
      for j = 1, #line do
        setCell(frame, cx, cy, line:sub(j, j), nil, clip)
        cx = cx + 1
      end
    end
  end
  -- "newline": nothing to paint -- it already reserved its space during
  -- measure()/position().
end

local DEFAULT_STYLE_KEY = "-1:-1:0:0:0:0:0:0"

local function styleKey(cell)
  return (cell.fg or -1) .. ":" .. (cell.bg or -1) .. ":"
    .. (cell.bold and 1 or 0) .. ":" .. (cell.dim and 1 or 0) .. ":"
    .. (cell.italic and 1 or 0) .. ":" .. (cell.underline and 1 or 0) .. ":"
    .. (cell.strikethrough and 1 or 0) .. ":" .. (cell.inverse and 1 or 0)
end

local function sgrFor(cell)
  local seq = "\27[0m"
  if cell.bold then seq = seq .. "\27[1m" end
  if cell.dim then seq = seq .. "\27[2m" end
  if cell.italic then seq = seq .. "\27[3m" end
  if cell.underline then seq = seq .. "\27[4m" end
  if cell.inverse then seq = seq .. "\27[7m" end
  if cell.strikethrough then seq = seq .. "\27[9m" end
  if cell.fg then seq = seq .. "\27[3" .. cell.fg .. "m" end
  if cell.bg then seq = seq .. "\27[4" .. cell.bg .. "m" end
  return seq
end

--- Encodes columns [c1..c2] of `row` as a byte string, switching SGR
--- state only when the active style actually changes cell-to-cell (real
--- style-run coalescing, not a fresh reset+code pair on every
--- character) and leaving the terminal in the default (reset) style
--- when the run ends on anything but the default, so a subsequent
--- unrelated write (a shell prompt, a later diff run) never inherits a
--- stray color.
local function encodeRun(row, c1, c2)
  local parts = {}
  local lastKey = nil
  for x = c1, c2 do
    local cell = row[x]
    local key = styleKey(cell)
    if key ~= lastKey then
      table.insert(parts, sgrFor(cell))
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
  return a.ch ~= b.ch or a.fg ~= b.fg or a.bg ~= b.bg or a.bold ~= b.bold
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

  local host = {}

  local root = { id = 0, type = "root", tag = "ROOT", props = {}, children = {}, parent = nil }

  function host.getRoot()
    return root
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
    detachFromParent(child)
    child.parent = parent
    table.insert(parent.children, child)
    host._dirty = true
  end

  function host.insertBefore(parent, child, beforeChild)
    if not parent or not child then return end
    detachFromParent(child)
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
    host._dirty = true
  end

  function host.commitTextUpdate(node, oldText, newText)
    if not node then return end
    node.text = tostring(newText or "")
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
    local yogaNodes = {}
    local rootYoga = buildYogaTree(root, yogaNodes)
    rootYoga:calculateLayout(YG_UNDEFINED, YG_UNDEFINED)
    resolvePositions(root, 1, 1) -- 1-indexed frame coordinates, see resolvePositions()
    freeYogaTree(yogaNodes)

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
        table.insert(buf, encodeRun(frame.rows[y], 1, w))
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
            table.insert(buf, encodeRun(newRow, runStart, x - 1))
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

  return host
end

return M
