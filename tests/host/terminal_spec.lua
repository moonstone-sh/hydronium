--[[
  Hydronium Ink terminal Host adapter -- real verification, not a mock.

  Proves src/hydronium/host/terminal.lua against the real
  core/reconciler.lua Reconciler (the same one every other host in this
  repo is proven against -- TestHost via tests/core/*, the real DOM host
  via the browser proofs cited in docs/HMR_GENERALIZATION_RESULTS.md),
  by capturing the exact bytes the host writes and reconstructing the
  resulting character+style grid from them: an ANSI escape-sequence
  interpreter (below) that tracks cursor position, active SGR style
  (fg color, bold), \27[2J full-clear, and \27[K clear-to-end-of-line --
  the complete, small vocabulary this host's paint() actually emits (see
  that file's own doc comment). This is deliberately more robust than
  asserting an exact byte string: it verifies the RENDERED PICTURE is
  correct regardless of incidental choices in how the host coalesces
  style-change runs, matching this repo's existing rigor bar (see
  tests/core/hydration_spec.lua's structural assertions rather than
  vague "contains some markup" checks).
--]]

local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert

local H = require("hydronium")
local ink = require("hydronium_ink")
local terminalHostModule = require("hydronium_ink.host.terminal")
local measure = require("hydronium_ink.measure")
local textMetrics = require("hydronium_ink.text_metrics")

-- ===================== Test-only ANSI interpreter =====================
-- Not part of the host implementation -- exists purely so this spec can
-- assert on the REAL rendered picture instead of raw bytes. Understands
-- exactly the escape vocabulary host/terminal.lua emits: cursor moves
-- (\27[<row>;<col>H), full clear (\27[2J), clear-to-end-of-line (\27[K),
-- SGR reset/bold/fg-color (\27[0m, \27[1m, \27[3<n>m), and DEC private
-- modes (\27[?25l/h cursor hide/show, \27[?2026h/l synchronized-update
-- brackets -- see host/terminal.lua's "CURSOR HIDE/SHOW"/flicker-fix
-- comment). The private-mode ones are recognized ONLY so they're
-- correctly consumed as one escape sequence rather than mis-tokenized as
-- literal printable text (which would shift every subsequent column) --
-- they have no grid effect to apply, matching how a real terminal would
-- silently act on \27[?25l/h (genuinely invisible to a grid model that,
-- like this one, has no cursor cell) and \27[?2026h/l (a real terminal's
-- OWN internal render-buffering signal, again nothing a static
-- reconstructed grid would ever show either way). A UTF-8
-- continuation-byte-aware character scanner ensures a 3-byte
-- box-drawing character (e.g. "\226\148\140" = U+250C) is reconstructed
-- as ONE grid cell/terminal column, not three -- proving the emitted
-- box-drawing bytes are real, well-formed multi-byte UTF-8 rather than
-- accidentally-mangled output.

local function utf8SeqLen(byte0)
  if byte0 >= 0xF0 then return 4
  elseif byte0 >= 0xE0 then return 3
  elseif byte0 >= 0xC0 then return 2
  else return 1 end
end

local function blankCell()
  return { ch = " ", fg = nil, bg = nil, bold = false, dim = false, italic = false, underline = false, strikethrough = false, inverse = false }
end

local function newGrid(w, h)
  local grid = {}
  for y = 1, h do
    local row = {}
    for x = 1, w do
      row[x] = blankCell()
    end
    grid[y] = row
  end
  return grid
end

--- Interprets `bytes` starting from `grid` (or a fresh blank w x h grid),
--- returning the resulting grid. Passing the previous call's result back
--- in lets a test interpret a stream incrementally, matching how a real
--- terminal accumulates state across writes.
---
--- Understands exactly the escape vocabulary host/terminal.lua emits
--- (see that module's own sgrFor()): SGR reset/bold/dim/italic/
--- underline/inverse/strikethrough/fg/bg (\27[0m, \27[1m, \27[2m,
--- \27[3m, \27[4m, \27[7m, \27[9m, \27[3<n>m, \27[4<n>m), cursor moves,
--- full clear, and clear-to-end-of-line.
local function interpretAnsi(bytes, w, h, grid)
  grid = grid or newGrid(w, h)
  local row, col = 1, 1
  local fg, bg, bold, dim, italic, underline, strikethrough, inverse = nil, nil, false, false, false, false, false, false
  local i, n = 1, #bytes

  local function resetStyle()
    fg, bg, bold, dim, italic, underline, strikethrough, inverse = nil, nil, false, false, false, false, false, false
  end

  while i <= n do
    if bytes:byte(i) == 27 and bytes:sub(i + 1, i + 1) == "[" then
      local s, e, params, cmd = bytes:find("^%[(%??[%d;]*)(%a)", i + 1)
      if not s then
        i = i + 1
      else
        if cmd == "h" or cmd == "l" then
          -- DEC private mode set/reset (\27[?25l, \27[?25h, \27[?2026h,
          -- \27[?2026l, ...): consumed above via the `%??` in the pattern
          -- so it doesn't get mis-tokenized as text, and deliberately a
          -- no-op here -- see this section's own top comment.
        elseif cmd == "H" then
          local rs, cs = params:match("(%d*);?(%d*)")
          row = tonumber(rs) or 1
          col = tonumber(cs) or 1
        elseif cmd == "J" then
          grid = newGrid(w, h)
        elseif cmd == "K" then
          for x = col, w do
            grid[row][x] = blankCell()
          end
        elseif cmd == "m" then
          if params == "" or params == "0" then
            resetStyle()
          else
            for code in params:gmatch("%d+") do
              local num = tonumber(code)
              if num == 0 then
                resetStyle()
              elseif num == 1 then
                bold = true
              elseif num == 2 then
                dim = true
              elseif num == 3 then
                italic = true
              elseif num == 4 then
                underline = true
              elseif num == 7 then
                inverse = true
              elseif num == 9 then
                strikethrough = true
              elseif num >= 30 and num <= 37 then
                fg = num - 30
              elseif num >= 40 and num <= 47 then
                bg = num - 40
              end
            end
          end
        end
        i = e + 1
      end
    else
      -- Decodes ONE grapheme cluster (not just one UTF-8 codepoint), via
      -- the SAME hydronium_ink.text_metrics the real host uses, and
      -- advances `col` by its real display width (2 for CJK/emoji, 0 for
      -- a lone combining mark) rather than always 1. This matters for a
      -- wide cluster specifically because the byte stream never contains
      -- a second character for its "second" column -- host/terminal.lua's
      -- own paintClusters() deliberately never writes one (see its doc
      -- comment): a real terminal auto-advances two columns for one wide
      -- glyph on its own, so this interpreter has to know to do the same
      -- to keep reconstructing the right column positions for whatever
      -- comes after.
      local b0 = bytes:byte(i)
      local seqLen = (b0 and b0 >= 0xC0) and utf8SeqLen(b0) or 1
      -- Bounded to the next ESC (or end of string): clusters() must never
      -- see into a following ANSI escape sequence, since it would treat
      -- ESC (a C0 control, zero-width per codepointWidth) as a combining
      -- continuation of whatever real character precedes it.
      local escAt = bytes:find("\27", i, true)
      local textSpan = escAt and bytes:sub(i, escAt - 1) or bytes:sub(i)
      local firstCluster = textMetrics.clusters(textSpan)[1]
      local ch, width = bytes:sub(i, i + seqLen - 1), 1
      if firstCluster then
        ch, width = firstCluster.text, firstCluster.width
      end
      if row >= 1 and row <= h and col >= 1 and col <= w then
        grid[row][col] = {
          ch = ch, fg = fg, bg = bg, bold = bold, dim = dim, italic = italic,
          underline = underline, strikethrough = strikethrough, inverse = inverse,
        }
      end
      col = col + width
      i = i + #ch
    end
  end

  return grid
end

local function rowText(grid, y, x1, x2)
  local parts = {}
  for x = x1, x2 do
    table.insert(parts, grid[y][x].ch)
  end
  return table.concat(parts)
end

-- Returns the writes table, the writer closure to hand to
-- createTerminalHost, and a clear() that empties the SAME table object
-- in place -- deliberately not "just reassign the local `writes`
-- variable to {}" at call sites, since `capture` closes over this
-- function's own `writes` upvalue: rebinding a caller-side local named
-- `writes` to a new table would silently disconnect it from `capture`,
-- which would keep writing into the original (now-orphaned) table.
local function newCapture()
  local writes = {}
  local function capture(s)
    table.insert(writes, s)
  end
  local function clear()
    for i = #writes, 1, -1 do
      writes[i] = nil
    end
  end
  return writes, capture, clear
end

-- ===================== Specs =====================

describe("hydronium.host.terminal -- real Host contract + real ANSI output", function()
  it("renders a bordered column Box with two styled Text children to the exact expected character grid", function()
    local writes, capture, clearWrites = newCapture()
    local host = terminalHostModule.createTerminalHost(capture)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    local vnode = H.h(ink.Box, { borderStyle = "single", flexDirection = "column", paddingX = 1 },
      H.h(ink.Text, { bold = true }, "Bold Line"),
      H.h(ink.Text, { color = "red" }, "Red Line")
    )

    reconciler:mount(vnode, root)
    host.flush() -- see host/terminal.lua's "REPAINT STRATEGY": mutating
                 -- host calls only mark the tree dirty; flush() is the
                 -- explicit commit-boundary this host's own API requires.

    assert.truthy(#writes > 0, "mounting must produce at least one real write")
    local allBytes = table.concat(writes)

    -- Real, well-formed ANSI: every escape must be one this interpreter
    -- (built purely from the module's own documented vocabulary)
    -- recognizes -- an unrecognized/garbled sequence would desync the
    -- interpreter's cursor tracking and corrupt every assertion below.
    local grid = interpretAnsi(allBytes, 20, 10)

    -- Layout: contentW = max(#"Bold Line", #"Red Line") = max(9, 8) = 9
    -- outerW = 9 + 2*paddingX(1) + 2*border(1) = 13
    -- outerH = 2 lines + 2*border(1) = 4
    assert.equal(rowText(grid, 1, 1, 13), "\226\148\140" .. string.rep("\226\148\128", 11) .. "\226\148\144",
      "top border row must be a real single-line box-drawing rule")
    assert.equal(rowText(grid, 4, 1, 13), "\226\148\148" .. string.rep("\226\148\128", 11) .. "\226\148\152",
      "bottom border row must be a real single-line box-drawing rule")

    assert.equal(rowText(grid, 2, 1, 13), "\226\148\130 Bold Line \226\148\130",
      "row 2 must be the left border, one space of paddingX, the bold text, one space, the right border")
    assert.equal(rowText(grid, 3, 1, 13), "\226\148\130 Red Line  \226\148\130",
      "row 3 must be the left border, paddingX, the red text, the leftover content-width filler space, paddingX, the right border")

    -- Per-cell style: "Bold Line" must be bold with no color; "Red Line"
    -- must carry fg=1 (red, SGR 31) with no bold -- proving the SGR
    -- state, not just the characters, is correct at each position.
    for i = 1, #("Bold Line") do
      local cell = grid[2][2 + i]
      assert.truthy(cell.bold, "expected bold at row 2 col " .. (2 + i))
      assert.is_nil(cell.fg, "expected no color at row 2 col " .. (2 + i))
    end
    for i = 1, #("Red Line") do
      local cell = grid[3][2 + i]
      assert.falsy(cell.bold, "expected no bold at row 3 col " .. (2 + i))
      assert.equal(cell.fg, 1, "expected fg=1 (red) at row 3 col " .. (2 + i))
    end
    -- Border/padding cells must carry no leftover style from the text
    -- runs beside them.
    assert.is_nil(grid[1][1].fg)
    assert.falsy(grid[1][1].bold)
    assert.is_nil(grid[2][13].fg, "right border of row 2 must not inherit bold's style")
    assert.falsy(grid[2][13].bold)
  end)

  it("lays out a row Box and a Newline-split Text block correctly", function()
    local writes, capture, clearWrites = newCapture()
    local host = terminalHostModule.createTerminalHost(capture)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    -- Row layout: two plain Text children side by side, no border/padding.
    local rowVNode = H.h(ink.Box, { flexDirection = "row" },
      H.h(ink.Text, nil, "AB"),
      H.h(ink.Text, nil, "CD")
    )
    reconciler:mount(rowVNode, root)
    host.flush()
    local grid = interpretAnsi(table.concat(writes), 20, 10)
    assert.equal(rowText(grid, 1, 1, 4), "ABCD", "row flexDirection must place the second Text immediately after the first, not stacked")

    reconciler:unmount(rowVNode)
    host.removeChild(root, rowVNode.hostNode)
    host.flush()

    -- A Newline inside a single Text intrinsic must force a real second
    -- line within that Text's own multi-line block, growing its height.
    clearWrites()
    local newlineVNode = H.h(ink.Text, nil, "Line1", H.h(ink.Newline), "Line2")
    reconciler:mount(newlineVNode, root)
    host.flush()
    local grid2 = interpretAnsi(table.concat(writes), 20, 10)
    assert.equal(rowText(grid2, 1, 1, 5), "Line1")
    assert.equal(rowText(grid2, 2, 1, 5), "Line2")
  end)

  it("drives a real stateful component's update through the ORDINARY reconciler path and repaints only the changed cell", function()
    local writes, capture, clearWrites = newCapture()
    local host = terminalHostModule.createTerminalHost(capture)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    local count, setCount = H.signal(1)

    local function Counter()
      -- Setup-once/render-many closure component (see
      -- tests/core/component_spec.lua's own such components) -- the
      -- point of this test is that this is an ORDINARY Hydronium
      -- component, not a hand-rolled repaint call.
      return function()
        return H.h(ink.Box, { borderStyle = "single" },
          H.h(ink.Text, nil, "Count: " .. tostring(count()))
        )
      end
    end

    reconciler:mount(H.h(Counter), root)
    host.flush()
    local initialWrites = #writes
    assert.truthy(initialWrites > 0)
    local initialByteLen = #table.concat(writes)

    local initialGrid = interpretAnsi(table.concat(writes), 20, 10)
    assert.equal(rowText(initialGrid, 2, 2, 9), "Count: 1")

    -- Drive the update the same way real component code would: mutate
    -- the signal. H.act() (this repo's existing test synchronization
    -- utility, see tests/core/component_spec.lua) just wraps
    -- scheduler.flush() around it -- setCount()'s own setter already
    -- flushes synchronously outside a render/effect phase (see
    -- signals/signal.lua), so this exercises the exact same path real
    -- application code takes.
    clearWrites()
    H.act(function()
      setCount(2)
    end)
    host.flush()

    assert.truthy(#writes > 0, "the signal update must produce a real repaint write")

    -- Reconstruct the grid by feeding ONLY this second write's bytes
    -- back into the grid already produced by the first paint --
    -- proving the second paint is a real, minimal DIFF (touching only
    -- the changed digit's cell), not a second full redraw: if it were a
    -- full redraw, the box-drawing border characters would also
    -- reappear in this second byte stream and this interpretation would
    -- still happen to work, so the actual proof of "diff, not
    -- redraw" is the byte-count assertion below, not this grid check
    -- alone.
    local updatedGrid = interpretAnsi(table.concat(writes), 20, 10, initialGrid)
    assert.equal(rowText(updatedGrid, 2, 2, 9), "Count: 2")
    -- The border must be untouched (still present) after the diff-only update.
    assert.equal(updatedGrid[1][1].ch, "\226\148\140")
    assert.equal(updatedGrid[3][1].ch, "\226\148\148")

    -- Real diff proof: the update's own byte stream must be far smaller
    -- than a full redraw of the same frame would be (a full redraw
    -- re-emits every one of the frame's ~30 cells with \27[K clears per
    -- row; a single-character diff is a handful of bytes) -- and must
    -- NOT contain \27[2J (the full-clear sequence only a full redraw
    -- ever emits).
    local updateBytes = table.concat(writes)
    assert.falsy(updateBytes:find("\27%[2J", 1, false), "a same-size update must never re-clear the whole screen")
    -- A relative bound, not a magic absolute one: every changed paint now
    -- carries a small FIXED per-paint wrapper (DEC 2026 synchronized-
    -- update brackets + cursor hide/show, see host/terminal.lua's "CURSOR
    -- HIDE/SHOW" comment) on top of its actual diff content, so an
    -- absolute byte ceiling here would need updating every time that
    -- fixed overhead changes for an unrelated reason. What actually
    -- matters -- and what a real regression back to full-redraw-on-every-
    -- update would blow through -- is that a one-character diff stays a
    -- small fraction of what the SAME host's own real initial full
    -- redraw cost, not some independently-chosen constant.
    assert.truthy(#updateBytes < initialByteLen / 2,
      "a single-character diff (" .. #updateBytes .. " bytes) must be far smaller than a full-frame redraw (" .. initialByteLen .. " bytes), not comparable to one")
  end)

  it("never emits a wrong-order intermediate frame when a multi-child Box re-renders (regression: reconcileChildren's unconditional re-append)", function()
    -- This regression exists because it was ACTUALLY OBSERVED on real
    -- stdout while building this host: core/reconciler.lua's
    -- reconcileChildren() unconditionally re-appends every child at the
    -- end of every reconcile "to ensure physical sibling order," one
    -- appendChild() call per child, even when the order didn't change.
    -- With an eager "paint on every mutating call" host (this module's
    -- first design), each of those individual appendChild() calls moved
    -- one child to the end of the internal children array, and painting
    -- after each one meant flushing a real, briefly-WRONG-order frame to
    -- the terminal before the final correct order was reached a few
    -- calls later -- visible flicker on a real pty (see
    -- docs/HYDRONIUM_INK_TERMINAL_HOST.md's "Repaint strategy" section
    -- for the actual captured bytes). The fix (dirty-flag + explicit
    -- host.flush(), see host/terminal.lua) means a whole reconcile's
    -- worth of appendChild/commitUpdate/commitTextUpdate calls collapses
    -- into exactly ONE real diff+paint -- this test proves that
    -- collapse actually happens, not just that the final state is
    -- eventually right (the removed synchronous-per-call design would
    -- ALSO have eventually reached the right final state; the bug was
    -- entirely about the wrong frames flushed on the way there).
    local writes, capture, clearWrites = newCapture()
    local host = terminalHostModule.createTerminalHost(capture)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    local count, setCount = H.signal(1)

    local function App()
      return function()
        return H.h(ink.Box, { flexDirection = "column" },
          H.h(ink.Text, nil, "Top"),
          H.h(ink.Text, nil, "Count: " .. tostring(count())),
          H.h(ink.Text, nil, "Bottom")
        )
      end
    end

    reconciler:mount(H.h(App), root)
    host.flush()
    assert.equal(#writes, 1, "the initial mount must collapse to exactly one write")
    local initialGrid = interpretAnsi(table.concat(writes), 20, 10)

    clearWrites()
    H.act(function()
      setCount(2)
    end)
    -- Deliberately calling host.flush() only ONCE here, after every
    -- mutating host call the update triggered has already happened
    -- (H.act's scheduler.flush() ran the whole render+commit
    -- synchronously) -- this is the actual point being tested.
    host.flush()

    assert.equal(#writes, 1,
      "a whole reconcile (commitUpdate + 3x commitTextUpdate/appendChild-for-order) must collapse into exactly one flush() write, never one write per mutating call")

    -- Feed the update's bytes onto the grid the initial mount already
    -- produced (matching how a real terminal accumulates state across
    -- writes) -- a minimal diff only touches the changed cells, so
    -- interpreting it against a fresh blank grid would wrongly show
    -- "Top"/"Bottom" as never having been painted at all.
    local grid = interpretAnsi(table.concat(writes), 20, 10, initialGrid)
    assert.equal(rowText(grid, 1, 1, 3), "Top", "row 1 must never have been anything other than 'Top'")
    assert.equal(rowText(grid, 2, 1, 8), "Count: 2")
    assert.equal(rowText(grid, 3, 1, 6), "Bottom", "row 3 must never have been anything other than 'Bottom'")
  end)

  it("blanks previously painted cells when content is unmounted", function()
    local writes, capture, clearWrites = newCapture()
    local host = terminalHostModule.createTerminalHost(capture)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    local vnode = H.h(ink.Text, nil, "X")
    reconciler:mount(vnode, root)
    host.flush()
    local grid = interpretAnsi(table.concat(writes), 20, 10)
    assert.equal(grid[1][1].ch, "X")

    clearWrites()
    reconciler:unmount(vnode)
    host.removeChild(root, vnode.hostNode)
    host.flush()

    assert.truthy(#writes > 0, "removing the only content must produce a real repaint")
    local grid2 = interpretAnsi(table.concat(writes), 20, 10, grid)
    assert.equal(grid2[1][1].ch, " ", "the cell that held 'X' must be blanked, not left stale")
  end)

  -- The specs below exercise real Yoga flexbox behavior the old
  -- block-stacking layout (measure()/position() in host/terminal.lua,
  -- before the swap to hydronium_ink.yoga_ffi) had no way to produce at
  -- all -- there was no concept of flexGrow/flexShrink/justifyContent/
  -- alignItems/flexWrap anywhere in that implementation.

  it("distributes remaining space to a flexGrow child in a row Box", function()
    local writes, capture, clearWrites = newCapture()
    local host = terminalHostModule.createTerminalHost(capture)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    -- width=20 row Box: a flexGrow=1 child must expand to fill everything
    -- the fixed-width=5 sibling doesn't use (20 - 5 = 15), not just be
    -- sized to its own single-character content like the old layout
    -- would have done.
    local vnode = H.h(ink.Box, { flexDirection = "row", width = 20 },
      H.h(ink.Box, { flexGrow = 1 }, H.h(ink.Text, nil, "L")),
      H.h(ink.Box, { width = 5 }, H.h(ink.Text, nil, "R"))
    )
    reconciler:mount(vnode, root)
    host.flush()

    assert.truthy(#writes > 0, "mounting must produce at least one real write")
    local grid = interpretAnsi(table.concat(writes), 20, 1)
    assert.equal(grid[1][1].ch, "L", "the flexGrow child's own content stays left-aligned within its grown box")
    assert.equal(grid[1][16].ch, "R", "the fixed-width=5 sibling must start at column 16 (20 - 5 + 1), proving the first box actually grew to 15 columns wide")
  end)

  it("honors justifyContent and alignItems on a Box with room to spare", function()
    local writes, capture, clearWrites = newCapture()
    local host = terminalHostModule.createTerminalHost(capture)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    -- A fixed 10-wide row Box containing one single-character Text child,
    -- centered via justifyContent -- with no flexGrow/shrink anywhere,
    -- the only way this child ends up away from column 1 is if
    -- justifyContent is real.
    local vnode = H.h(ink.Box, { flexDirection = "row", width = 9, justifyContent = "center" },
      H.h(ink.Text, nil, "X")
    )
    reconciler:mount(vnode, root)
    host.flush()

    assert.truthy(#writes > 0, "mounting must produce at least one real write")
    local grid = interpretAnsi(table.concat(writes), 9, 1)
    assert.equal(grid[1][5].ch, "X", "a single-cell child centered in a 9-wide Box must land at column 5, not column 1")
    assert.equal(grid[1][1].ch, " ", "columns before the centered child must be blank")
    assert.equal(grid[1][9].ch, " ", "columns after the centered child must be blank")
  end)

  -- The specs below exercise Phase 2's remaining Box/Text props (margin,
  -- absolute positioning, backgroundColor, per-edge border color,
  -- overflow=hidden clipping, Text's italic/underline/strikethrough/
  -- inverse/dimColor, and the truncate wrap variants) -- none of these
  -- existed before this pass.

  it("applies real Yoga margin, offsetting a child's position without changing its own size", function()
    local writes, capture, clearWrites = newCapture()
    local host = terminalHostModule.createTerminalHost(capture)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    local vnode = H.h(ink.Box, { flexDirection = "column" },
      H.h(ink.Box, { margin = 2 }, H.h(ink.Text, nil, "X"))
    )
    reconciler:mount(vnode, root)
    host.flush()

    local grid = interpretAnsi(table.concat(writes), 6, 6)
    assert.equal(grid[3][3].ch, "X", "a margin=2 box's single-char child must land at row 3, col 3 (2 rows/cols of margin, 1-indexed)")
    assert.equal(grid[1][1].ch, " ", "the margin area itself must be blank")
  end)

  it("positions a child absolutely at an explicit top/left, independent of normal flow", function()
    local writes, capture, clearWrites = newCapture()
    local host = terminalHostModule.createTerminalHost(capture)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    local vnode = H.h(ink.Box, { width = 10, height = 3 },
      H.h(ink.Box, { position = "absolute", top = 1, left = 4 }, H.h(ink.Text, nil, "A"))
    )
    reconciler:mount(vnode, root)
    host.flush()

    local grid = interpretAnsi(table.concat(writes), 10, 3)
    assert.equal(grid[2][5].ch, "A", "top=1 left=4 (0-indexed Yoga coords) must land at row 2 col 5 (1-indexed)")
  end)

  it("fills a Box's real backgroundColor and colors border characters with borderColor", function()
    local writes, capture, clearWrites = newCapture()
    local host = terminalHostModule.createTerminalHost(capture)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    local vnode = H.h(ink.Box, { borderStyle = "single", borderColor = "red", backgroundColor = "blue", width = 5, height = 3 })
    reconciler:mount(vnode, root)
    host.flush()

    local grid = interpretAnsi(table.concat(writes), 5, 3)
    assert.equal(grid[1][1].fg, 1, "top-left corner must carry borderColor=red (fg=1)")
    assert.equal(grid[1][1].bg, 4, "the border cell itself must also carry backgroundColor=blue (bg=4)")
    assert.equal(grid[2][2].bg, 4, "interior (non-border) cells must also carry backgroundColor=blue")
    assert.is_nil(grid[2][2].fg, "interior cells have no fg of their own -- only the background fill")
  end)

  it("resolves a specific border edge color over the box-wide borderColor fallback", function()
    local writes, capture, clearWrites = newCapture()
    local host = terminalHostModule.createTerminalHost(capture)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    local vnode = H.h(ink.Box, { borderStyle = "single", borderColor = "red", borderTopColor = "green", width = 5, height = 3 })
    reconciler:mount(vnode, root)
    host.flush()

    local grid = interpretAnsi(table.concat(writes), 5, 3)
    assert.equal(grid[1][2].fg, 2, "top edge must use borderTopColor=green (fg=2), overriding borderColor")
    assert.equal(grid[2][1].fg, 1, "left edge (no override) must fall back to borderColor=red (fg=1)")
  end)

  it("clips a child's overflowing content to its own box when overflow=hidden, without affecting a sibling", function()
    local writes, capture, clearWrites = newCapture()
    local host = terminalHostModule.createTerminalHost(capture)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    local vnode = H.h(ink.Box, { flexDirection = "row" },
      H.h(ink.Box, { width = 5, height = 1, overflow = "hidden" }, H.h(ink.Text, nil, "HELLOWORLD")),
      H.h(ink.Box, { width = 5, height = 1 }, H.h(ink.Text, nil, "SIDE"))
    )
    reconciler:mount(vnode, root)
    host.flush()

    local grid = interpretAnsi(table.concat(writes), 10, 1)
    assert.equal(rowText(grid, 1, 1, 10), "HELLOSIDE ", "overflowing 'WORLD' must be clipped, and the sibling's own 'SIDE' must be untouched")
  end)

  it("renders a controlled overflow=scroll viewport and exposes its clamped metrics", function()
    local writes, capture, clearWrites = newCapture()
    local host = terminalHostModule.createTerminalHost(capture)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)
    local viewportRef = H.createRef()

    reconciler:mount(H.h(ink.Box, { ref = viewportRef, width = 5, height = 2, overflow = "scroll", scrollTop = 1 },
      H.h(ink.Text, nil, "first"),
      H.h(ink.Text, nil, "second"),
      H.h(ink.Text, nil, "third")
    ), root)
    host.flush()

    local grid = interpretAnsi(table.concat(writes), 5, 2)
    assert.equal(rowText(grid, 1, 1, 5), "secon")
    assert.equal(rowText(grid, 2, 1, 5), "third")
    local metrics = measure.measureElement(viewportRef)
    assert.equal(metrics.scrollTop, 1)
    assert.equal(metrics.scrollMaxTop, 1)

    clearWrites()
    reconciler:reconcile(H.h(ink.Box, { ref = viewportRef, width = 5, height = 2, overflow = "scroll", scrollTop = 99 },
      H.h(ink.Text, nil, "first"),
      H.h(ink.Text, nil, "second"),
      H.h(ink.Text, nil, "third")
    ), root)
    host.flush()
    assert.equal(measure.measureElement(viewportRef).scrollTop, 1, "out-of-range controlled offsets clamp to the content")

    writes, capture, clearWrites = newCapture()
    host = terminalHostModule.createTerminalHost(capture)
    root = host.getRoot()
    reconciler = H.Reconciler.new(host)
    reconciler:mount(H.h(ink.Box, { width = 5, height = 1, overflow = "scroll", scrollLeft = 3 },
      H.h(ink.Text, nil, "ABCDEFGHIJ")
    ), root)
    host.flush()
    grid = interpretAnsi(table.concat(writes), 5, 1)
    assert.equal(rowText(grid, 1, 1, 5), "DEFGH", "horizontal offsets use the same controlled viewport contract")
  end)

  it("applies real SGR codes for italic, underline, strikethrough, inverse, and dimColor", function()
    local writes, capture, clearWrites = newCapture()
    local host = terminalHostModule.createTerminalHost(capture)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    local vnode = H.h(ink.Text, { italic = true, underline = true, strikethrough = true, inverse = true, dimColor = true }, "X")
    reconciler:mount(vnode, root)
    host.flush()

    local grid = interpretAnsi(table.concat(writes), 1, 1)
    local cell = grid[1][1]
    assert.truthy(cell.italic, "expected SGR 3 (italic)")
    assert.truthy(cell.underline, "expected SGR 4 (underline)")
    assert.truthy(cell.strikethrough, "expected SGR 9 (strikethrough)")
    assert.truthy(cell.inverse, "expected SGR 7 (inverse)")
    assert.truthy(cell.dim, "expected SGR 2 (dim)")
  end)

  it("lowers absolute colors to the selected truecolor, ANSI-256, or ANSI-16 target while palette names remain themed", function()
    local writes, capture = newCapture()
    local host = terminalHostModule.createTerminalHost(capture)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)
    reconciler:mount(H.h(ink.Text, { color = "#112233" }, "X"), root)

    host.setColorCapability("truecolor")
    host.flush()
    assert.truthy(table.concat(writes):find("\27[38;2;17;34;51m", 1, true))

    writes, capture = newCapture()
    host = terminalHostModule.createTerminalHost(capture)
    root, reconciler = host.getRoot(), H.Reconciler.new(host)
    reconciler:mount(H.h(ink.Text, { color = "#112233" }, "X"), root)
    host.setColorCapability("ansi256")
    host.flush()
    assert.truthy(table.concat(writes):find("\27[38;5;", 1, true))

    writes, capture = newCapture()
    host = terminalHostModule.createTerminalHost(capture)
    root, reconciler = host.getRoot(), H.Reconciler.new(host)
    reconciler:mount(H.h(ink.Text, { color = "red" }, "X"), root)
    host.setColorCapability("truecolor")
    host.flush()
    assert.truthy(table.concat(writes):find("\27[31m", 1, true), "palette names must use the terminal's live palette slot")
  end)

  it("truncates Text to fit an explicit width with truncate/truncate-start/truncate-middle", function()
    local cases = {
      { wrap = "truncate", expected = "Hello..." },
      { wrap = "truncate-start", expected = "...World" },
      { wrap = "truncate-middle", expected = "He...rld" },
    }
    for _, c in ipairs(cases) do
      local writes, capture, clearWrites = newCapture()
      local host = terminalHostModule.createTerminalHost(capture)
      local root = host.getRoot()
      local reconciler = H.Reconciler.new(host)

      reconciler:mount(H.h(ink.Text, { width = 8, wrap = c.wrap }, "HelloWorld"), root)
      host.flush()

      local grid = interpretAnsi(table.concat(writes), 8, 1)
      assert.equal(rowText(grid, 1, 1, 8), c.expected, "wrap=" .. c.wrap)
    end
  end)

  -- The specs below exercise Phase 3's Spacer, measureElement, and
  -- Transform -- none of these existed before this pass. `Static` is
  -- deliberately NOT covered here (and not implemented) -- see
  -- docs/HYDRONIUM_INK_TERMINAL_HOST.md's "Explicitly NOT implemented"
  -- section for why it needs a genuinely different rendering mode this
  -- host doesn't have yet, not just a new prop.

  it("expands a real Spacer to consume the remaining space along the main flex axis", function()
    local writes, capture, clearWrites = newCapture()
    local host = terminalHostModule.createTerminalHost(capture)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    local vnode = H.h(ink.Box, { flexDirection = "row", width = 10 },
      H.h(ink.Text, nil, "L"),
      H.h(ink.Spacer),
      H.h(ink.Text, nil, "R")
    )
    reconciler:mount(vnode, root)
    host.flush()

    local grid = interpretAnsi(table.concat(writes), 10, 1)
    assert.equal(rowText(grid, 1, 1, 10), "L        R", "Spacer must push R all the way to the last column")
  end)

  it("measureElement(ref) reports real x/y/width/height/clientWidth/clientHeight from a bound ref", function()
    local writes, capture, clearWrites = newCapture()
    local host = terminalHostModule.createTerminalHost(capture)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    local boxRef = H.createRef()
    assert.equal(measure.measureElement(boxRef).hasMeasured, false, "an unbound/unpainted ref must report hasMeasured=false")

    reconciler:mount(
      H.h(ink.Box, { ref = boxRef, borderStyle = "single", padding = 1, width = 10, height = 5 }),
      root
    )
    host.flush()

    local m = measure.measureElement(boxRef)
    assert.truthy(m.hasMeasured)
    assert.equal(m.x, 1)
    assert.equal(m.y, 1)
    assert.equal(m.width, 10)
    assert.equal(m.height, 5)
    assert.equal(m.clientWidth, 6, "10 - 2*border(1) - 2*padding(1)")
    assert.equal(m.clientHeight, 1, "5 - 2*border(1) - 2*padding(1)")
  end)

  -- host.invalidate() exists for exactly one real caller today:
  -- render.lua switching into/out of the terminal's alternate screen
  -- buffer (\27[?1049h/l), which replaces the visible screen with one
  -- sharing none of the previous frame's cells. Without this, the next
  -- paint would emit only the cells that changed in the Lua-side grid and
  -- leave the rest of the frame missing on the newly-switched screen.
  it("invalidate() forces the next flush to repaint in full instead of diffing against a frame the terminal no longer shows", function()
    local writes, capture, clearWrites = newCapture()
    local host = terminalHostModule.createTerminalHost(capture)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    reconciler:mount(H.h(ink.Text, {}, "hello"), root)
    host.flush()
    assert.truthy(table.concat(writes):find("\27[2J", 1, true),
      "the very first paint is always a full clear+redraw (no previous frame to diff against)")

    clearWrites()
    host.flush()
    assert.equal(#writes, 0, "a flush with nothing dirty must write nothing at all")

    host.invalidate()
    assert.is_nil(host.getLastFrame(), "invalidate() must drop the cached previous frame")
    host.flush()

    local bytes = table.concat(writes)
    assert.truthy(bytes:find("\27[2J", 1, true), "invalidate() must force a full clear+redraw")
    local grid = interpretAnsi(bytes, 10, 1)
    assert.equal(rowText(grid, 1, 1, 5), "hello",
      "the whole frame must be repainted, not just the cells that changed since the last paint")
  end)

  it("Transform renders its children in isolation and applies transform(line, index) to each plain-text output line", function()
    local writes, capture, clearWrites = newCapture()
    local host = terminalHostModule.createTerminalHost(capture)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    local vnode = H.h(ink.Transform, { transform = function(line, i) return i .. ":" .. line end },
      H.h(ink.Text, nil,
        H.h(ink.Text, nil, "line one"),
        H.h(ink.Newline),
        H.h(ink.Text, nil, "line two")
      )
    )
    reconciler:mount(vnode, root)
    host.flush()

    local grid = interpretAnsi(table.concat(writes), 10, 2)
    assert.equal(rowText(grid, 1, 1, 10), "1:line one")
    assert.equal(rowText(grid, 2, 1, 10), "2:line two")
    assert.is_nil(grid[1][1].fg, "Transform output is plain, unstyled text -- no fg color of its own")
  end)

  it("parses ANSI SGR returned by Transform into styled terminal cells", function()
    local writes, capture, clearWrites = newCapture()
    local host = terminalHostModule.createTerminalHost(capture)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    reconciler:mount(H.h(ink.Transform, {
      transform = function(line) return "\27[31m" .. line .. "\27[0m" end,
    }, H.h(ink.Text, nil, "red")), root)
    host.flush()

    local grid = interpretAnsi(table.concat(writes), 3, 1)
    assert.equal(rowText(grid, 1, 1, 3), "red")
    assert.equal(grid[1][1].fg, 1)
  end)

  it("parses truecolor ANSI returned by Transform without carrying styles past SGR reset", function()
    local writes, capture = newCapture()
    local host = terminalHostModule.createTerminalHost(capture)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)
    reconciler:mount(H.h(ink.Transform, {
      transform = function() return "\27[1;38;2;1;2;3mA\27[0mB" end,
    }, H.h(ink.Text, nil, "x")), root)
    host.setColorCapability("truecolor")
    host.flush()
    local bytes = table.concat(writes)
    assert.truthy(bytes:find("\27[38;2;1;2;3m", 1, true))
    assert.truthy(bytes:find("\27[0mB", 1, true), "reset must clear Transform styles before the following cell")
  end)

  -- The specs below exercise Unicode-aware measurement/painting
  -- (hydronium_ink.text_metrics), real word-wrap, and terminal-
  -- constrained root layout -- none of which existed before this pass.
  -- Previously every one of these iterated `#text` BYTES per cell, so a
  -- multi-byte character (accented Latin, CJK, emoji) was split across
  -- as many cells as it had bytes.

  it("renders multi-byte and wide characters as one cell each, not split across their bytes", function()
    local writes, capture, clearWrites = newCapture()
    local host = terminalHostModule.createTerminalHost(capture)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    -- "café" (é precomposed, 2 bytes) + "日本" (2 wide CJK chars, 3 bytes
    -- each) -- 4 narrow cells + 2 wide (4-cell) cells = 8 cells, 12 bytes.
    reconciler:mount(H.h(ink.Text, {}, "café\230\151\165\230\156\172"), root)
    host.flush()

    local grid = interpretAnsi(table.concat(writes), 8, 1)
    assert.equal(rowText(grid, 1, 1, 4), "café", "the accented character must be one cell, not two")
    assert.equal(grid[1][5].ch, "\230\151\165", "the first CJK character occupies its own cell")
    assert.equal(grid[1][7].ch, "\230\156\172", "the second CJK character starts right after the first one's 2 cells")

    -- The continuation cell itself is never written to the byte stream at
    -- all (a real terminal auto-advances 2 columns for one wide glyph, so
    -- writing a second character there would consume a THIRD column) --
    -- check the host's own internal frame, not the ANSI-reconstructed
    -- grid, which can only ever show its last-painted content (a blank
    -- space, from the initial clear) at a position nothing ever wrote to.
    local internalFrame = host.getLastFrame()
    assert.equal(internalFrame.rows[1][6].ch, "", "a wide character's second cell must be an empty continuation, not a copy of the glyph")
  end)

  it("measures a Box's width by real display width, not byte count, so a CJK child is not clipped", function()
    local writes, capture, clearWrites = newCapture()
    local host = terminalHostModule.createTerminalHost(capture)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    -- 2 wide CJK chars = 4 display cells but 6 bytes; a byte-counting
    -- Box would sizeShrink to 6 (fine) but a byte-counting Text leaf
    -- would claim width 6 instead of 4, corrupting a row layout next to it.
    local vnode = H.h(ink.Box, { flexDirection = "row" },
      H.h(ink.Text, nil, "\230\151\165\230\156\172"),
      H.h(ink.Text, nil, "|")
    )
    reconciler:mount(vnode, root)
    host.flush()

    local grid = interpretAnsi(table.concat(writes), 5, 1)
    assert.equal(grid[1][5].ch, "|", "the second Text must start at cell 5 (4 display cells, not 6 bytes)")
  end)

  it("truncates Text to fit an explicit width when the content includes wide characters", function()
    local writes, capture, clearWrites = newCapture()
    local host = terminalHostModule.createTerminalHost(capture)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    -- "AB" + 3 wide CJK chars (6 display cells) = 8 cells total, truncated to 5.
    reconciler:mount(H.h(ink.Text, { width = 5, wrap = "truncate" }, "AB\230\151\165\230\156\172\230\151\165"), root)
    host.flush()

    local grid = interpretAnsi(table.concat(writes), 5, 1)
    -- "AB" (2 cells) + one wide char (2 cells) = 4 cells, then "..." would
    -- overflow -- the wide char must be dropped whole, not split, leaving
    -- "AB" + marker clipped to the 5-cell budget.
    assert.equal(grid[1][1].ch, "A")
    assert.equal(grid[1][2].ch, "B")
    assert.truthy(grid[1][3].ch == "." or grid[1][3].ch == "\230\151\165",
      "must not cut a wide character in half to make room for the marker")
  end)

  it("wraps Text at word boundaries to an explicit width instead of overflowing", function()
    local writes, capture, clearWrites = newCapture()
    local host = terminalHostModule.createTerminalHost(capture)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    reconciler:mount(H.h(ink.Text, { width = 5, wrap = "wrap" }, "one two three"), root)
    host.flush()

    local grid = interpretAnsi(table.concat(writes), 5, 3)
    assert.equal(rowText(grid, 1, 1, 5):gsub("%s+$", ""), "one")
    assert.equal(rowText(grid, 2, 1, 5):gsub("%s+$", ""), "two")
    assert.equal(rowText(grid, 3, 1, 5):gsub("%s+$", ""), "three", "an overlong word keeps its own (overflowing) line without being split")
  end)

  it("hard-wraps a single overlong word across lines when wrap='hard'", function()
    local writes, capture, clearWrites = newCapture()
    local host = terminalHostModule.createTerminalHost(capture)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    reconciler:mount(H.h(ink.Text, { width = 4, wrap = "hard" }, "abcdefgh"), root)
    host.flush()

    local grid = interpretAnsi(table.concat(writes), 4, 2)
    assert.equal(rowText(grid, 1, 1, 4), "abcd")
    assert.equal(rowText(grid, 2, 1, 4), "efgh")
  end)

  it("wraps Text against a container's real resolved width when Text itself has no explicit width", function()
    local writes, capture, clearWrites = newCapture()
    local host = terminalHostModule.createTerminalHost(capture)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    -- The Box fixes the cross-axis width at 5; Yoga's default
    -- alignItems: stretch then gives the Text (no width of its own) that
    -- same 5-cell width -- the two-pass reflow in host.paint() must pick
    -- that resolved width up and wrap against it.
    local vnode = H.h(ink.Box, { width = 5 },
      H.h(ink.Text, { wrap = "wrap" }, "one two three")
    )
    reconciler:mount(vnode, root)
    host.flush()

    local grid = interpretAnsi(table.concat(writes), 5, 3)
    assert.equal(rowText(grid, 1, 1, 5):gsub("%s+$", ""), "one")
    assert.equal(rowText(grid, 2, 1, 5):gsub("%s+$", ""), "two")
    assert.equal(rowText(grid, 3, 1, 5):gsub("%s+$", ""), "three")
  end)

  it("constrains the root layout to a terminal size set via host.setSize, instead of auto-sizing to content", function()
    local writes, capture, clearWrites = newCapture()
    local host = terminalHostModule.createTerminalHost(capture)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    host.setSize(10, 4)
    -- A single narrow Text as the only child: with an unconstrained
    -- (auto-sizing-to-content) root, the frame would be exactly 2x1 --
    -- with a constrained root, it must be the full 10x4 terminal.
    reconciler:mount(H.h(ink.Text, nil, "hi"), root)
    host.flush()

    local frame = host.getLastFrame()
    assert.equal(frame.w, 10, "root width must be the terminal's real column count")
    assert.equal(frame.h, 4, "root height must be the terminal's real row count")
  end)

  it("stretches a childless-width Box to the real terminal width when the root is size-constrained", function()
    local writes, capture, clearWrites = newCapture()
    local host = terminalHostModule.createTerminalHost(capture)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    host.setSize(10, 1)
    local boxRef = H.createRef()
    reconciler:mount(H.h(ink.Box, { ref = boxRef, backgroundColor = "blue" }, H.h(ink.Text, nil, "x")), root)
    host.flush()

    local metrics = measure.measureElement(boxRef)
    assert.equal(metrics.width, 10, "a Box with no explicit width must stretch to the constrained root's real width")
  end)

  it("host.setSize(0, 0) (non-interactive/piped) goes back to auto-sizing the root to content", function()
    local writes, capture, clearWrites = newCapture()
    local host = terminalHostModule.createTerminalHost(capture)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    host.setSize(10, 4)
    host.setSize(0, 0) -- e.g. tty_ffi.getWindowSize() failing/unavailable
    reconciler:mount(H.h(ink.Text, nil, "hi"), root)
    host.flush()

    local frame = host.getLastFrame()
    assert.equal(frame.w, 2, "root must auto-size back to its content's width")
    assert.equal(frame.h, 1, "root must auto-size back to its content's height")
  end)

  -- The two specs below exercise incremental (persistent, patch-on-update)
  -- Yoga tree maintenance -- buildYogaTree() used to tear down and rebuild
  -- the WHOLE native Yoga tree from scratch on every single paint(); it
  -- now keeps one real Yoga node alive per host node across paints and
  -- patches only what a mutation's own dirty flags say actually changed.

  it("keeps a node's persistent Yoga node across paints, only re-syncing what actually changed", function()
    local writes, capture, clearWrites = newCapture()
    local host = terminalHostModule.createTerminalHost(capture)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    local count, setCount = H.signal(1)
    local function App()
      return function()
        return H.h(ink.Box, { flexDirection = "row" },
          H.h(ink.Text, nil, "static"),
          H.h(ink.Text, nil, tostring(count()))
        )
      end
    end

    reconciler:mount(H.h(App), root)
    host.flush()

    local box = root.children[1]
    local staticText = box.children[1]
    local boxYogaBefore, staticYogaBefore = box._yoga, staticText._yoga

    H.act(function() setCount(2) end)
    host.flush()

    assert.truthy(box._yoga == boxYogaBefore,
      "the Box's persistent Yoga node must be reused across paints, not recreated")
    assert.truthy(staticText._yoga == staticYogaBefore,
      "an unchanged sibling Text's persistent Yoga node must be reused, not recreated")
    assert.falsy(staticText._styleDirty, "an unchanged Text must not be left marked dirty")
    assert.falsy(box._childrenDirty, "an unchanged Box's child list must not be left marked dirty")

    local grid = interpretAnsi(table.concat(writes), 10, 1)
    assert.equal(rowText(grid, 1, 1, 7), "static2")
  end)

  it("frees a removed subtree's Yoga nodes via host.removeChild without corrupting a remaining sibling or a later remount", function()
    local writes, capture, clearWrites = newCapture()
    local host = terminalHostModule.createTerminalHost(capture)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    local showFirst, setShowFirst = H.signal(true)
    local function App()
      return function()
        return H.h(ink.Box, { flexDirection = "row" },
          showFirst() and H.h(ink.Text, { key = "a" }, "AAA") or nil,
          H.h(ink.Text, { key = "b" }, "BBB")
        )
      end
    end

    reconciler:mount(H.h(App), root)
    host.flush()
    assert.equal(rowText(interpretAnsi(table.concat(writes), 10, 1), 1, 1, 6), "AAABBB")

    clearWrites()
    H.act(function() setShowFirst(false) end)
    host.flush()
    assert.equal(rowText(interpretAnsi(table.concat(writes), 10, 1), 1, 1, 3), "BBB",
      "removing the first Text must free its Yoga node and leave the remaining sibling intact")

    -- Remount a brand-new "a" node (a real create, not a reuse of the
    -- freed one -- the reconciler never resurrects an unmounted vnode's
    -- host node) and paint again: this is the real regression case for a
    -- use-after-free/double-free bug in freeYogaSubtree, since it forces
    -- a fresh Yoga.newNode() call right after the previous one at that
    -- same conceptual tree position was freed.
    clearWrites()
    H.act(function() setShowFirst(true) end)
    host.flush()
    assert.equal(rowText(interpretAnsi(table.concat(writes), 10, 1), 1, 1, 6), "AAABBB")
  end)
end)

-- ===================== OSC 8 hyperlinks =====================
-- See host/terminal.lua's own "OSC 8 HYPERLINK GRID REPRESENTATION" and
-- "Hyperlink capability" comments for the design this exercises: `href`
-- is a per-run/per-cell style attribute (not bytes embedded in `.text`),
-- and whether it is ever emitted as real OSC 8 escapes is gated by
-- host.setHyperlinkCapability, independent of setColorCapability. Byte
-- assertions here are deliberately literal string finds (`, 1, true`),
-- not run through interpretAnsi above -- that interpreter has no OSC
-- vocabulary at all, and the whole point of these specs is to prove the
-- EXACT escape bytes (Task 1's own "verified at the byte level" bar), not
-- a reconstructed picture.
describe("hydronium.host.terminal -- OSC 8 hyperlinks", function()
  it("wraps a href Text run in the exact OSC 8 open/close bytes when hyperlink capability is forced on", function()
    local writes, capture = newCapture()
    local host = terminalHostModule.createTerminalHost(capture)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    host.setHyperlinkCapability(true)
    reconciler:mount(H.h(ink.Text, { href = "https://example.com" }, "click"), root)
    host.flush()

    local bytes = table.concat(writes)
    local expectedOpen = "\27]8;;https://example.com\27\\"
    local expectedClose = "\27]8;;\27\\"
    local openAt = bytes:find(expectedOpen, 1, true)
    local textAt = bytes:find("click", 1, true)
    local closeAt = bytes:find(expectedClose, 1, true)
    assert.truthy(openAt, "expected the exact OSC 8 open sequence ESC]8;;<uri>ESC\\")
    assert.truthy(textAt, "expected the visible text to still be painted")
    assert.truthy(closeAt, "expected the exact OSC 8 close sequence ESC]8;;ESC\\")
    assert.truthy(openAt < textAt, "the open sequence must precede the linked text")
    assert.truthy(textAt < closeAt, "the close sequence must follow the linked text")
  end)

  it("degrades to plain visible text with zero OSC 8 bytes when hyperlink capability is off", function()
    local writes, capture = newCapture()
    local host = terminalHostModule.createTerminalHost(capture)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    host.setHyperlinkCapability(false)
    reconciler:mount(H.h(ink.Text, { href = "https://example.com" }, "click"), root)
    host.flush()

    local bytes = table.concat(writes)
    assert.truthy(bytes:find("click", 1, true), "the visible text must still render even when the link is suppressed")
    assert.falsy(bytes:find("]8;;", 1, true),
      "no OSC 8 bytes at all when the capability is off -- not even a partial/garbage sequence a non-supporting terminal would show")
  end)

  it("splits adjacent same-styled cells into separate OSC 8 spans when their href differs", function()
    local writes, capture = newCapture()
    local host = terminalHostModule.createTerminalHost(capture)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    host.setHyperlinkCapability(true)
    reconciler:mount(
      H.h(ink.Text, nil,
        H.h(ink.Text, { href = "https://a.example" }, "A"),
        H.h(ink.Text, { href = "https://b.example" }, "B")
      ),
      root
    )
    host.flush()

    local bytes = table.concat(writes)
    assert.truthy(bytes:find("\27]8;;https://a.example\27\\A\27]8;;\27\\", 1, true),
      "the first link's span must close before the second one's opens, even with no style change between them")
    assert.truthy(bytes:find("\27]8;;https://b.example\27\\B\27]8;;\27\\", 1, true))
  end)

  it("a nested Text without its own href inherits the outer one, matching color's own inheritance", function()
    local writes, capture = newCapture()
    local host = terminalHostModule.createTerminalHost(capture)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    host.setHyperlinkCapability(true)
    reconciler:mount(
      H.h(ink.Text, { href = "https://example.com" }, H.h(ink.Text, { bold = true }, "bold link")),
      root
    )
    host.flush()

    local bytes = table.concat(writes)
    assert.truthy(bytes:find("\27]8;;https://example.com\27\\", 1, true), "the inherited href must still open a real OSC 8 span")
    assert.truthy(bytes:find("bold link", 1, true))
  end)

  it("measures and paints href text at the same width as the same visible text with no link -- OSC 8 bytes are zero-width", function()
    local plainWrites, plainCapture = newCapture()
    local plainHost = terminalHostModule.createTerminalHost(plainCapture)
    local plainRoot = plainHost.getRoot()
    local plainRef = H.createRef()
    plainHost.setHyperlinkCapability(true)
    H.Reconciler.new(plainHost):mount(H.h(ink.Box, { ref = plainRef }, H.h(ink.Text, nil, "click")), plainRoot)
    plainHost.flush()

    local linkWrites, linkCapture = newCapture()
    local linkHost = terminalHostModule.createTerminalHost(linkCapture)
    local linkRoot = linkHost.getRoot()
    local linkRef = H.createRef()
    linkHost.setHyperlinkCapability(true)
    H.Reconciler.new(linkHost):mount(
      H.h(ink.Box, { ref = linkRef }, H.h(ink.Text, { href = "https://example.com/a/very/long/path?q=1" }, "click")),
      linkRoot
    )
    linkHost.flush()

    local plainMetrics = measure.measureElement(plainRef)
    local linkMetrics = measure.measureElement(linkRef)
    assert.equal(linkMetrics.width, plainMetrics.width,
      "a linked Text's measured layout width must equal the same visible text with no link at all -- " ..
      "a regression here means OSC 8 escape bytes leaked into the width computation (see Task 1's own " ..
      "'Width' design note): every layout containing a link would silently be wrong")
    assert.equal(linkMetrics.height, plainMetrics.height)
    assert.equal(plainMetrics.width, textMetrics.displayWidth("click"), "sanity: the plain baseline itself must be the real visible-text width")

    -- Not cross-checked against interpretAnsi's reconstructed grid here:
    -- that helper only understands the CSI (`\27[`) vocabulary
    -- host/terminal.lua emits for cursor moves/SGR (see its own doc
    -- comment above), not OSC (`\27]`) -- feeding it OSC 8 bytes would
    -- make IT misparse the stream, not exercise a real bug in the host.
    -- The width/height equality above, plus the exact-byte assertions in
    -- the specs before this one, already cover both halves of the actual
    -- invariant (visible content unchanged, width unaffected by the link).
    assert.truthy(table.concat(linkWrites):find("click", 1, true))
  end)

  it("setHyperlinkCapability is independent of setColorCapability -- forcing color does not turn hyperlinks on", function()
    local writes, capture = newCapture()
    local host = terminalHostModule.createTerminalHost(capture)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    host.setColorCapability("truecolor")
    host.setHyperlinkCapability(false)
    reconciler:mount(H.h(ink.Text, { color = "#112233", href = "https://example.com" }, "X"), root)
    host.flush()

    local bytes = table.concat(writes)
    assert.truthy(bytes:find("\27[38;2;17;34;51m", 1, true), "truecolor SGR must still be emitted")
    assert.falsy(bytes:find("]8;;", 1, true), "hyperlink capability being off must suppress OSC 8 regardless of color capability")
  end)
end)

-- ===================== Cursor hide/show + synchronized output =====================
-- See host/terminal.lua's own "CURSOR HIDE/SHOW" comment inside paint()'s
-- `if changed then` block for the full design rationale: hiding the real
-- cursor for the duration of a redraw (restoring to whatever
-- host._cursorVisible last was, NOT unconditionally showing) removes the
-- cursor-darting flicker a scattered multi-run diff produces, and
-- bracketing the whole write in DEC 2026 (`\27[?2026h`/`l`) prevents a
-- large single write() (worst case: the full-redraw path) from tearing
-- across the terminal's own reads. Both MUST live inside the `changed`
-- guard -- the entire point of these specs is proving the zero-byte
-- no-op guarantee survives adding them, not just that the bytes exist.
describe("hydronium.host.terminal -- paint() cursor hide/show + synchronized output", function()
  it("wraps a changed FULL-REDRAW paint in DEC 2026 sync brackets with cursor hide/show innermost, in the right order", function()
    local writes, capture = newCapture()
    local host = terminalHostModule.createTerminalHost(capture)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    reconciler:mount(H.h(ink.Text, nil, "hi"), root)
    host.flush()

    local bytes = table.concat(writes)
    assert.truthy(bytes:find("\27[2J", 1, true), "sanity: this must be the full-redraw path (first paint)")

    local syncOpenAt = bytes:find("\27[?2026h", 1, true)
    local hideAt = bytes:find("\27[?25l", 1, true)
    local clearAt = bytes:find("\27[2J", 1, true)
    local showAt = bytes:find("\27[?25h", 1, true)
    local syncCloseAt = bytes:find("\27[?2026l", 1, true)
    assert.truthy(syncOpenAt, "expected the synchronized-update open bracket")
    assert.truthy(hideAt, "expected the cursor-hide sequence")
    assert.truthy(showAt, "expected the cursor-show sequence (default host cursor visibility is true)")
    assert.truthy(syncCloseAt, "expected the synchronized-update close bracket")
    assert.truthy(syncOpenAt < hideAt, "the sync bracket must be OUTERMOST, opening before the cursor is hidden")
    assert.truthy(hideAt < clearAt, "the cursor must be hidden before the full-redraw content is written")
    assert.truthy(clearAt < showAt, "the cursor must be shown again only after the frame content")
    assert.truthy(showAt < syncCloseAt, "the sync bracket must close only after the cursor is shown again")

    -- Exact byte adjacency, not just ordering: the write must OPEN with
    -- sync-then-hide and CLOSE with show-then-sync, with nothing else
    -- interleaved at either end.
    assert.equal(bytes:sub(1, 8), "\27[?2026h")
    assert.equal(bytes:sub(9, 14), "\27[?25l")
    assert.equal(bytes:sub(-14), "\27[?25h\27[?2026l")
  end)

  it("wraps a changed INCREMENTAL diff paint in the same brackets, with no full-clear", function()
    local writes, capture, clearWrites = newCapture()
    local host = terminalHostModule.createTerminalHost(capture)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    local count, setCount = H.signal(1)
    local function Counter()
      return function() return H.h(ink.Text, nil, "n=" .. tostring(count())) end
    end
    reconciler:mount(H.h(Counter), root)
    host.flush()

    clearWrites()
    H.act(function() setCount(2) end)
    host.flush()

    local bytes = table.concat(writes)
    assert.falsy(bytes:find("\27[2J", 1, true), "sanity: this must be the incremental-diff path, not a full redraw")
    assert.truthy(#bytes > 0, "sanity: the count change must still produce a real write")
    assert.equal(bytes:sub(1, 8), "\27[?2026h", "the diff path must be sync-bracketed exactly like the full-redraw path")
    assert.equal(bytes:sub(9, 14), "\27[?25l")
    assert.equal(bytes:sub(-14), "\27[?25h\27[?2026l")
  end)

  it("restores to HIDDEN, not shown, when the app had explicitly hidden the cursor via host.setCursorVisible(false)", function()
    local writes, capture, clearWrites = newCapture()
    local host = terminalHostModule.createTerminalHost(capture)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    local count, setCount = H.signal(1)
    local function Counter()
      return function() return H.h(ink.Text, nil, "n=" .. tostring(count())) end
    end
    reconciler:mount(H.h(Counter), root)
    host.flush()

    -- Simulates what session.lua's context.setCursorPosition(nil) does:
    -- informs the host the app explicitly wants the cursor hidden, fully
    -- independent of this host's own paint()-time hide/show.
    host.setCursorVisible(false)

    clearWrites()
    H.act(function() setCount(2) end)
    host.flush()

    local bytes = table.concat(writes)
    assert.truthy(bytes:find("\27[?25l", 1, true), "the transient paint-time hide must still happen")
    assert.falsy(bytes:find("\27[?25h", 1, true),
      "must NOT re-show the cursor after the redraw -- the app explicitly hid it, and paint() restoring to \"visible\" unconditionally would silently undo that (see host/terminal.lua's own doc comment on this exact trap)")
    assert.truthy(bytes:find("\27[?2026h", 1, true) and bytes:find("\27[?2026l", 1, true), "sync brackets must still wrap the write regardless of cursor visibility")
  end)

  it("an unchanged paint (nothing visually different) writes ZERO bytes -- not even the hide/sync-open bytes", function()
    local writes, capture, clearWrites = newCapture()
    local host = terminalHostModule.createTerminalHost(capture)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    reconciler:mount(H.h(ink.Text, nil, "static"), root)
    host.flush()
    assert.truthy(#writes > 0, "sanity: the first paint must write something")

    clearWrites()
    -- Reconciling to an IDENTICAL tree still re-runs commitTextUpdate/
    -- appendChild (see host/terminal.lua's own "REPAINT STRATEGY" comment
    -- -- core/reconciler.lua's reconcileChildren always re-appends "to
    -- ensure sibling order" even when nothing moved), so this is a real
    -- structurally-non-trivial call, not a hand-wavy no-op -- yet nothing
    -- VISIBLE changed. Calling host.paint() directly (not host.flush())
    -- proves the `changed` flag INSIDE paint() itself is what suppresses
    -- output, independent of the dirty-flag gate flush() has -- the exact
    -- guarantee item 1/2's hide/show and sync brackets must not break.
    reconciler:reconcile(H.h(ink.Text, nil, "static"), root)
    host.paint()

    assert.equal(#writes, 0,
      "a visually no-op paint must write NOTHING -- not even the new cursor-hide or sync-open bytes -- " ..
      "or every structurally-harmless reconciler commit would spam the output stream with escape sequences that have no visible effect")
  end)
end)

-- ===================== O(N) re-render (was O(N^2)) =====================
-- See host/terminal.lua's own "FIXED SCALING COST"/"Sibling list" comments
-- for the full history: core/reconciler.lua's reconcileChildren calls
-- host.appendChild for EVERY child on EVERY re-render "to ensure sibling
-- order," even when nothing moved, and the OLD appendChild/detachFromParent
-- implemented that via a plain array (linear scan + table.remove shift),
-- making a Box with N children re-render in O(N^2). Both specs below are
-- self-contained (measure only the CURRENT code's own scaling behavior
-- against itself at different N, not a comparison against a historical
-- version) so they need nothing outside this repo to run.
--
-- A real before/after comparison against the actual pre-fix code (loaded
-- via `git show HEAD:ink/src/hydronium_ink/host/terminal.lua`, calling the
-- REAL old `host.appendChild` directly, not a reimplementation) was run
-- once during development, not committed as a permanent spec (a historical
-- comparison isn't something a future checkout can reproduce on its own):
--
--   N      OLD host.appendChild (x N)   NEW host.appendChild (x N)   speedup
--   500    0.19 ms                      0.02 ms                      9.9x
--   1000   0.66 ms                      0.03 ms                     24.4x
--   2000   2.53 ms                      0.04 ms                     66.3x
--   4000   9.60 ms                      0.05 ms                    186.0x
--   8000  38.94 ms                      0.11 ms                    365.3x
--
-- OLD scaling ~3.5-4.1x per doubling (textbook O(N^2)); NEW well under
-- 2x per doubling. The growing speedup (not a flat constant factor) is
-- the actual signature of a complexity-CLASS change, not just a faster
-- constant. See this session's own final report for the exact commands.
describe("hydronium.host.terminal -- O(N) re-render (was O(N^2))", function()
  it("host.appendChild, called for every child in order (the exact core/reconciler.lua pattern), scales roughly linearly with N", function()
    local function timeReappendAll(n, iterations)
      local host = terminalHostModule.createTerminalHost(function() end)
      local root = host.getRoot()
      local kids = {}
      for i = 1, n do
        kids[i] = host.createInstance("Text", {})
        host.appendChild(root, kids[i])
      end
      host.flush()

      local start = os.clock()
      for _ = 1, iterations do
        for i = 1, n do
          host.appendChild(root, kids[i])
        end
      end
      return (os.clock() - start) / iterations
    end

    local tSmall = timeReappendAll(500, 20)
    local tLarge = timeReappendAll(8000, 20) -- 16x the N of tSmall
    print(string.format("[bench] host.appendChild x N: N=500 -> %.5fms, N=8000 -> %.5fms (ratio %.2fx for 16x N)",
      tSmall * 1000, tLarge * 1000, tLarge / tSmall))

    -- O(N) predicts ~16x for a 16x increase in N; O(N^2) predicts ~256x.
    -- 40x leaves generous headroom for timing noise/GC/JIT warmup while
    -- still flatly rejecting quadratic behavior, which this bound is
    -- actually wide enough to have caught on the OLD code (it measured
    -- ~205x for this exact 500->8000 comparison during development).
    assert.truthy(tLarge / tSmall < 40,
      string.format("expected roughly linear scaling (~16x for 16x N), got %.1fx -- looks quadratic again", tLarge / tSmall))
  end)

  it("a real Box with N children, re-rendered repeatedly via the ordinary reconciler path, does not exhibit quadratic blowup", function()
    local unpack_ = table.unpack or unpack

    local function timeOneUpdate(n, iterations)
      local host = terminalHostModule.createTerminalHost(function() end)
      local root = host.getRoot()
      local reconciler = H.Reconciler.new(host)

      local count, setCount = H.signal(0)
      local function App()
        return function()
          -- N keyed Text children -- only the first's own text actually
          -- changes across renders, but core/reconciler.lua's
          -- reconcileChildren re-appends ALL of them "to ensure sibling
          -- order" every single time regardless (see this file's own
          -- REPAINT STRATEGY comment) -- the exact scenario this fix
          -- targets, driven through the REAL public render path (mount +
          -- signal update + flush), not a host-internals shortcut.
          local kids = {}
          for i = 1, n do
            kids[i] = H.h(ink.Text, { key = "t" .. i }, i == 1 and ("n=" .. tostring(count())) or ("row" .. i))
          end
          return H.h(ink.Box, nil, unpack_(kids))
        end
      end

      reconciler:mount(H.h(App), root)
      host.flush()

      local start = os.clock()
      for i = 1, iterations do
        H.act(function() setCount(i) end)
        host.flush()
      end
      return (os.clock() - start) / iterations
    end

    local tSmall = timeOneUpdate(250, 5)
    local tLarge = timeOneUpdate(2000, 5) -- 8x the N of tSmall
    print(string.format("[bench] real Box re-render: N=250 -> %.3fms/update, N=2000 -> %.3fms/update (ratio %.2fx for 8x N)",
      tSmall * 1000, tLarge * 1000, tLarge / tSmall))

    -- HONEST NOTE (see this session's final report for the full writeup):
    -- at this N range, END-TO-END wall-clock is dominated by costs this
    -- fix does NOT touch -- rebuilding N fresh vnodes via H.h() every
    -- render, and core/reconciler.lua's own O(N) keyed-diff bookkeeping
    -- -- not by host.appendChild's own array-vs-linked-list cost (that
    -- part's real, dramatic, isolated speedup is the spec above). This
    -- assertion is deliberately a much looser sanity bound than the
    -- isolated one above: it only rules out the full pipeline going
    -- quadratic (which it would, eventually, without this fix, just at
    -- an N far larger than is realistic for a terminal UI -- see the
    -- report for the crossover estimate), not a claim that this fix
    -- alone makes end-to-end re-renders faster at N=2000.
    assert.truthy(tLarge / tSmall < 16,
      string.format("expected sub-quadratic end-to-end scaling (linear would be ~8x for 8x N), got %.1fx", tLarge / tSmall))
  end)
end)
