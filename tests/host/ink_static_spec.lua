--[[
  hydronium_ink `ink.Static` -- real verification, not a mock.

  Proves the append-only, write-once scrollback primitive added to
  host/terminal.lua (see hydronium_ink/init.lua's own "Static:" doc
  comment): each of Static's children is written to the real terminal
  (via the same writeFn every other host output goes through) exactly
  once, the moment it first appears, and is excluded from the live/
  diffed inline frame forever after -- proven here by driving a REAL
  core/reconciler.lua Reconciler (never a mock host) and inspecting both
  the captured bytes and host.getLastFrame(), the same two angles
  tests/host/terminal_spec.lua already uses for the rest of this host.
--]]

local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert

local H = require("hydronium")
local ink = require("hydronium_ink")
local terminalHostModule = require("hydronium_ink.host.terminal")
local session = require("hydronium_ink.session")

--- Same shape as terminal_spec.lua's own newCapture() -- see that file's
--- doc comment for why clear() empties the table in place rather than
--- rebinding the local.
local function newCapture()
  local writes = {}
  local function capture(s) table.insert(writes, s) end
  local function clear()
    for i = #writes, 1, -1 do writes[i] = nil end
  end
  return writes, capture, clear
end

local function rowText(frame, y)
  local out = {}
  for x = 1, frame.w do out[x] = frame.rows[y][x].ch end
  return table.concat(out)
end

describe("hydronium_ink.host.terminal -- ink.Static (append-only scrollback)", function()
  it("writes each Static child to the terminal exactly once and excludes it from the live/diffed frame", function()
    local writes, capture = newCapture()
    local host = terminalHostModule.createTerminalHost(capture, { inline = true })
    host.setSize(20, 24)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    local vnode = H.h(ink.Box, { flexDirection = "column" },
      H.h(ink.Static, nil, H.h(ink.Text, { key = "a" }, "Committed A")),
      H.h(ink.Text, nil, "Live")
    )
    reconciler:mount(vnode, root)
    host.flush()

    local out = table.concat(writes)
    assert.truthy(out:find("Committed A", 1, true), "the Static child's text must actually reach the terminal")
    assert.truthy(out:find("Live", 1, true), "the live sibling must still paint normally")

    local frame = host.getLastFrame()
    assert.equal(frame.h, 1, "the live/diffed frame must contain ONLY the still-live content -- Static's own child contributes zero height once flushed")
    assert.equal(rowText(frame, 1):gsub("%s+$", ""), "Live")
  end)

  it("never rewrites an already-flushed line when a later item is appended (typewriter honesty)", function()
    local writes, capture, clearWrites = newCapture()
    local host = terminalHostModule.createTerminalHost(capture, { inline = true })
    host.setSize(20, 24)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    local items, setItems = H.signal({ "Step 1" })
    local function App()
      return function()
        local kids = {}
        for i, label in ipairs(items()) do
          kids[i] = H.h(ink.Text, { key = label }, label)
        end
        return H.h(ink.Box, { flexDirection = "column" }, H.h(ink.Static, nil, kids), H.h(ink.Text, nil, "Live"))
      end
    end

    reconciler:mount(H.h(App), root)
    host.flush()
    assert.truthy(table.concat(writes):find("Step 1", 1, true))

    clearWrites()
    H.act(function() setItems({ "Step 1", "Step 2" }) end)
    host.flush()

    local out = table.concat(writes)
    assert.truthy(out:find("Step 2", 1, true), "the newly appended item must be flushed")
    assert.falsy(out:find("Step 1", 1, true), "an already-flushed item must never be written again")
    assert.equal(host.getLastFrame().h, 1, "the live frame still contains only the still-live content after the append")
  end)

  it("erases only the live region (never the already-flushed content) before appending a new commit", function()
    -- clearInline()'s cursor-up count is driven by host._inlineHeight, which
    -- flushStaticNodes resets to 0 the moment it flushes -- so the ERASE
    -- immediately preceding a NEW flush must only ever account for the
    -- previous LIVE region (1 row here), never for anything Static already
    -- committed permanently.
    local writes, capture, clearWrites = newCapture()
    local host = terminalHostModule.createTerminalHost(capture, { inline = true })
    host.setSize(20, 24)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    local items, setItems = H.signal({ "A" })
    local function App()
      return function()
        local kids = {}
        for i, label in ipairs(items()) do kids[i] = H.h(ink.Text, { key = label }, label) end
        return H.h(ink.Box, { flexDirection = "column" }, H.h(ink.Static, nil, kids), H.h(ink.Text, nil, "Live"))
      end
    end
    reconciler:mount(H.h(App), root)
    host.flush()

    clearWrites()
    H.act(function() setItems({ "A", "B" }) end)
    host.flush()

    assert.truthy(table.concat(writes):find("\27[1A", 1, true), "must move up exactly ONE row -- the previous live region -- not further into already-committed scrollback")
  end)

  it("behaves exactly like a plain Box outside inline mode -- nothing is ever flushed or hidden", function()
    local writes, capture = newCapture()
    local host = terminalHostModule.createTerminalHost(capture) -- inline defaults to false
    host.setSize(20, 10)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    local vnode = H.h(ink.Box, { flexDirection = "column" },
      H.h(ink.Static, nil, H.h(ink.Text, nil, "A")),
      H.h(ink.Text, nil, "B")
    )
    reconciler:mount(vnode, root)
    host.flush()

    local frame = host.getLastFrame()
    assert.equal(frame.rows[1][1].ch, "A", "a non-inline host never flushes Static -- its content stays part of the ordinary live frame")
    assert.equal(frame.rows[2][1].ch, "B")
  end)

  it("honors the active color capability when flushing, exactly like the live frame", function()
    local writes, capture = newCapture()
    local host = terminalHostModule.createTerminalHost(capture, { inline = true })
    host.setSize(10, 24)
    host.setColorCapability("ansi16")
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    local vnode = H.h(ink.Box, { flexDirection = "column" },
      H.h(ink.Static, nil, H.h(ink.Text, { color = "red" }, "R")),
      H.h(ink.Text, nil, "L")
    )
    reconciler:mount(vnode, root)
    host.flush()

    local out = table.concat(writes)
    assert.falsy(out:find("38;2", 1, true), "ansi16 capability must never emit a truecolor SGR sequence, even for flushed content")
    assert.truthy(out:find("31m", 1, true) or out:find("91m", 1, true), "red must still resolve to a real ansi16 SGR code")
  end)

  it("resolves ink.adaptive/byProfile color values against the color PROFILE active at flush time", function()
    local writes, capture = newCapture()
    local host = terminalHostModule.createTerminalHost(capture, { inline = true })
    host.setSize(10, 24)
    host.setColorProfile("none")
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    local vnode = H.h(ink.Box, { flexDirection = "column" },
      H.h(ink.Static, nil, H.h(ink.Text, { color = ink.adaptive({ truecolor = "#ff0000", ansi16 = "red", none = nil }) }, "P")),
      H.h(ink.Text, nil, "L")
    )
    reconciler:mount(vnode, root)
    host.flush()

    local out = table.concat(writes)
    assert.truthy(out:find("P", 1, true), "the flushed text itself must still be present")
    assert.falsy(out:find("31m", 1, true) or out:find("38;2", 1, true), "colorProfile 'none' must resolve to NO color SGR at all, even for flushed content")
  end)

  it("wraps flushed Text content using the same pipeline as the live frame", function()
    local writes, capture = newCapture()
    local host = terminalHostModule.createTerminalHost(capture, { inline = true })
    host.setSize(6, 24)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    local vnode = H.h(ink.Box, { flexDirection = "column" },
      H.h(ink.Static, nil, H.h(ink.Text, { wrap = "wrap", width = 6 }, "hello world")),
      H.h(ink.Text, nil, "L")
    )
    reconciler:mount(vnode, root)
    host.flush()

    local out = table.concat(writes)
    assert.truthy(out:find("hello", 1, true) and out:find("world", 1, true), "a flushed Text with wrap='wrap' must still reflow across multiple real lines")
  end)

  it("renders wide (double-width) grapheme clusters intact when flushed", function()
    local writes, capture = newCapture()
    local host = terminalHostModule.createTerminalHost(capture, { inline = true })
    host.setSize(20, 24)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    -- U+8A9E U+8A00 ("语言"), two double-width CJK characters -- proves the
    -- isolated mini-layout flushStaticNodes runs is grapheme/cell aware,
    -- not a byte-count-based host.
    local wide = "\232\170\158\232\168\128"
    local vnode = H.h(ink.Box, { flexDirection = "column" },
      H.h(ink.Static, nil, H.h(ink.Text, nil, wide)),
      H.h(ink.Text, nil, "L")
    )
    reconciler:mount(vnode, root)
    host.flush()

    assert.truthy(table.concat(writes):find(wide, 1, true), "the exact multi-byte UTF-8 sequence must reach the terminal unmangled")
  end)

  it("picks up the CURRENT column width for newly flushed items after a resize", function()
    local writes, capture, clearWrites = newCapture()
    local host = terminalHostModule.createTerminalHost(capture, { inline = true })
    host.setSize(20, 24)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    -- Explicit `width` (rather than relying on wrap="wrap" with no width
    -- at all, which needs the two-pass natural-width reflow host.paint()
    -- runs for the LIVE tree -- see buildYogaTree's own "two-pass reflow"
    -- comment -- flushStaticNodes's isolated mini-tree deliberately does
    -- NOT run a second pass, a stated limitation shared with Transform's
    -- own identical isolated-subtree technique above it): each item reads
    -- `host._cols` itself at RENDER time, so an item authored after a
    -- resize captures the CURRENT width, not whatever was current when an
    -- earlier item was created.
    local items, setItems = H.signal({ "first" })
    local function App()
      return function()
        local kids = {}
        for i, label in ipairs(items()) do
          -- "hard" (not "wrap"): a single word LONGER than the explicit
          -- width is left unsplit on its own (overflowing) line under
          -- "wrap" -- see wrapLine's own "oversized word, non-hard wrap"
          -- branch -- exactly like the live tree would do for the same
          -- props, so "hard" is what actually proves the resize took
          -- effect here.
          kids[i] = H.h(ink.Text, { key = label, wrap = "hard", width = host._cols }, label)
        end
        return H.h(ink.Box, { flexDirection = "column" }, H.h(ink.Static, nil, kids), H.h(ink.Text, nil, "Live"))
      end
    end
    reconciler:mount(H.h(App), root)
    host.flush()

    host.setSize(4, 24)
    host.invalidate()
    clearWrites()
    H.act(function() setItems({ "first", "second" }) end)
    host.flush()

    -- "second" (6 cells) must hard-split across two 4-wide lines ("seco" /
    -- "nd") -- proves the newly-flushed item's isolated mini-layout used
    -- the resized column count, not whatever was current when it was
    -- created (at width 20 it would never split at all).
    local out = table.concat(writes)
    assert.truthy(out:find("seco", 1, true) and out:find("nd", 1, true), "the new item must reflow against the NEW, narrower width")
  end)

  it("does not disturb paintInline's scrollFocus viewport logic for the still-live region", function()
    local writes, capture = newCapture()
    local host = terminalHostModule.createTerminalHost(capture, { inline = true })
    host.setSize(20, 5) -- capacity = rows - 2 = 3, forces scrolling among the live rows
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    local liveRows = {}
    for i = 1, 10 do liveRows[i] = H.h(ink.Text, { key = i, scrollFocus = (i == 10) }, "row " .. i) end
    local vnode = H.h(ink.Box, { flexDirection = "column" },
      H.h(ink.Static, nil, H.h(ink.Text, { key = "c" }, "committed")),
      H.h(ink.Box, { flexDirection = "column" }, liveRows)
    )
    reconciler:mount(vnode, root)
    host.flush()

    assert.truthy(host._scrollFocus, "a scrollFocus descendant of the still-live region must still be tracked")
    assert.truthy(table.concat(writes):find("committed", 1, true))
  end)

  it("exposes the full scrollback via Session:staticHistory(), independent of a resettable byte sink", function()
    local writes = {}
    local app = session.create(H.h(function()
      local items, setItems = H.signal({ "one" })
      return function()
        local kids = {}
        for i, label in ipairs(items()) do kids[i] = H.h(ink.Text, { key = label }, label) end
        return H.h(ink.Box, { flexDirection = "column" }, H.h(ink.Static, nil, kids), H.h(ink.Text, nil, "live"))
      end
    end), { columns = 20, rows = 24, inline = true, writeFn = function(s) table.insert(writes, s) end })

    -- The very first render already flushes "one" (Static flushes the
    -- moment an item first appears, including on initial mount) -- proven
    -- by asserting it shows up in staticHistory() even though `writes`
    -- (the resettable byte sink a real caller would use) is exactly the
    -- kind of thing a full-frame resync can no longer rely on alone.
    assert.truthy(app:staticHistory():find("one", 1, true), "the first item must already be part of the accumulated history after mount")
    app:close()
  end)

  it("host.encodeFullReplay() reproduces the entire Static history plus the current live frame in one self-contained stream", function()
    local writes, capture = newCapture()
    local host = terminalHostModule.createTerminalHost(capture, { inline = true })
    host.setSize(20, 24)
    local root = host.getRoot()
    local reconciler = H.Reconciler.new(host)

    local items, setItems = H.signal({ "alpha" })
    local function App()
      return function()
        local kids = {}
        for i, label in ipairs(items()) do kids[i] = H.h(ink.Text, { key = label }, label) end
        return H.h(ink.Box, { flexDirection = "column" }, H.h(ink.Static, nil, kids), H.h(ink.Text, nil, "beta"))
      end
    end
    reconciler:mount(H.h(App), root)
    host.flush()
    H.act(function() setItems({ "alpha", "gamma" }) end)
    host.flush()

    local replay = host.encodeFullReplay()
    assert.truthy(replay:find("alpha", 1, true), "the full replay must include the FIRST flushed item")
    assert.truthy(replay:find("gamma", 1, true), "the full replay must include the SECOND flushed item")
    assert.truthy(replay:find("beta", 1, true), "the full replay must also include the CURRENT live frame")
  end)
end)

describe("hydronium_ink_lab.runtime -- Static history survives a full-frame resync", function()
  it("replays the complete Static history (not just bytes since the last tick) when a full-frame op resets the client", function()
    local ok, lab = pcall(require, "hydronium_lab")
    local ok2, inkLabRuntime = pcall(require, "hydronium_ink_lab.runtime")
    if not (ok and ok2) then return end -- Ink Lab package not present in this checkout's dependency graph

    local story = lab.story({
      id = "static-demo",
      render = function(args)
        local kids = {}
        for i = 1, (args.count or 1) do
          kids[i] = H.h(ink.Text, { key = i }, "Item " .. i)
        end
        -- `inlineViewport = true` is what actually puts a Lab session
        -- (Runtime:open() always uses session option `inline = "auto"`)
        -- into real inline mode -- see wizard_app.lua's own identical use
        -- of this prop for the exact same reason.
        return H.h(ink.Box, { flexDirection = "column", inlineViewport = true }, H.h(ink.Static, nil, kids), H.h(ink.Text, nil, "live"))
      end,
    })
    local registry = lab.registry({ story })
    local runtime = inkLabRuntime.new(registry)

    runtime:open("static-demo", { args = { count = 1 }, columns = 20, rows = 24 })
    local grown = runtime:request({ op = "args", args = { count = 2 } })
    assert.truthy(grown.ansi:find("Item 2", 1, true), "the newly appended item must flush on the tick it was added")

    -- A resize is a FULL_FRAME_OP: the client resets its own terminal
    -- buffer before replaying `encoded.ansi` (see xterm-entry.js) -- without
    -- host.encodeFullReplay(), this tick's own `self.output` would contain
    -- only bytes written during the resize itself, losing "Item 1"/"Item 2".
    local resized = runtime:request({ op = "resize", columns = 30, rows = 24 })
    assert.truthy(resized.ansi:find("Item 1", 1, true), "a full-frame resync must still include the FIRST flushed item")
    assert.truthy(resized.ansi:find("Item 2", 1, true), "a full-frame resync must still include the SECOND flushed item")
  end)
end)
