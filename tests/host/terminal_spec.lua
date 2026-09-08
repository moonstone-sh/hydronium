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

-- ===================== Test-only ANSI interpreter =====================
-- Not part of the host implementation -- exists purely so this spec can
-- assert on the REAL rendered picture instead of raw bytes. Understands
-- exactly the escape vocabulary host/terminal.lua emits: cursor moves
-- (\27[<row>;<col>H), full clear (\27[2J), clear-to-end-of-line (\27[K),
-- and SGR reset/bold/fg-color (\27[0m, \27[1m, \27[3<n>m). A UTF-8
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

local function newGrid(w, h)
  local grid = {}
  for y = 1, h do
    local row = {}
    for x = 1, w do
      row[x] = { ch = " ", fg = nil, bold = false }
    end
    grid[y] = row
  end
  return grid
end

--- Interprets `bytes` starting from `grid` (or a fresh blank w x h grid),
--- returning the resulting grid. Passing the previous call's result back
--- in lets a test interpret a stream incrementally, matching how a real
--- terminal accumulates state across writes.
local function interpretAnsi(bytes, w, h, grid)
  grid = grid or newGrid(w, h)
  local row, col = 1, 1
  local fg, bold = nil, false
  local i, n = 1, #bytes

  while i <= n do
    if bytes:byte(i) == 27 and bytes:sub(i + 1, i + 1) == "[" then
      local s, e, params, cmd = bytes:find("^%[([%d;]*)(%a)", i + 1)
      if not s then
        i = i + 1
      else
        if cmd == "H" then
          local rs, cs = params:match("(%d*);?(%d*)")
          row = tonumber(rs) or 1
          col = tonumber(cs) or 1
        elseif cmd == "J" then
          grid = newGrid(w, h)
        elseif cmd == "K" then
          for x = col, w do
            grid[row][x] = { ch = " ", fg = nil, bold = false }
          end
        elseif cmd == "m" then
          if params == "" or params == "0" then
            fg, bold = nil, false
          else
            for code in params:gmatch("%d+") do
              local num = tonumber(code)
              if num == 0 then
                fg, bold = nil, false
              elseif num == 1 then
                bold = true
              elseif num >= 30 and num <= 37 then
                fg = num - 30
              end
            end
          end
        end
        i = e + 1
      end
    else
      local b0 = bytes:byte(i)
      local seqLen = (b0 and b0 >= 0xC0) and utf8SeqLen(b0) or 1
      local ch = bytes:sub(i, i + seqLen - 1)
      if row >= 1 and row <= h and col >= 1 and col <= w then
        grid[row][col] = { ch = ch, fg = fg, bold = bold }
      end
      col = col + 1
      i = i + seqLen
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
    assert.truthy(#updateBytes < 40, "a single-character diff must be a small handful of bytes, not a full-frame redraw")
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
end)
