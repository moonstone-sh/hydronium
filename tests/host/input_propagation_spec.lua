--[[
  Input propagation: deepest handler first, outward to the root, stoppable --
  with ordering derived from the component tree rather than declared.
--]]

local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert

local H = require("hydronium")
local ink = require("hydronium_ink")
local hooks = require("hydronium_ink.hooks")
local session = require("hydronium_ink.session")

--- Records into `log` on every key; optionally stops propagation.
local function Recorder(log, name, opts)
  opts = opts or {}
  return function()
    hooks.useInput(function(_, _, evt)
      log[#log + 1] = name
      if opts.consume then evt.stop() end
    end, { focusId = opts.focusId })
    return function()
      return H.h(ink.Box, {}, opts.children or H.h(ink.Text, {}, name))
    end
  end
end

--- Nests components so that each is one level deeper than the last.
local function nest(log, names, consumeAt)
  local function build(i)
    if i > #names then return nil end
    local inner = build(i + 1)
    return H.h(Recorder(log, names[i], {
      consume = (names[i] == consumeAt),
      children = inner,
    }))
  end
  return build(1)
end

local function run(element)
  local s = session.create(element, { writeFn = function() end, columns = 40, rows = 8 })
  s:write("x")
  s:close()
end

describe("hydronium_ink input -- propagation order comes from the tree", function()
  it("offers the event to the deepest handler first", function()
    local log = {}
    -- Mounted outermost-first; the DEEPEST must still be offered it first.
    run(nest(log, { "root", "screen", "field" }))
    assert.same(log, { "field", "screen", "root" })
  end)

  it("orders siblings at equal depth by registration", function()
    local log = {}
    run(H.h(ink.Box, {},
      H.h(Recorder(log, "first")),
      H.h(Recorder(log, "second"))))
    assert.same(log, { "first", "second" })
  end)

  it("needs no declaration -- nesting a component deeper is how it wins", function()
    local log = {}
    -- Same two components, opposite nesting. Ordering flips with structure,
    -- with nothing declared at either call site.
    run(nest(log, { "outer", "inner" }))
    assert.same(log, { "inner", "outer" })

    local flipped = {}
    run(nest(flipped, { "inner", "outer" }))
    assert.same(flipped, { "outer", "inner" })
  end)
end)

describe("hydronium_ink input -- stopping propagation", function()
  it("stops at the handler that calls evt.stop()", function()
    local log = {}
    run(nest(log, { "root", "screen", "field" }, "screen"))
    assert.same(log, { "field", "screen" }, "root must not see a stopped event")
  end)

  it("does not stop merely because a handler ran", function()
    -- Explicit, not "returned something truthy": an accidental truthy return
    -- would swallow every key with no visible cause.
    local log = {}
    run(nest(log, { "root", "field" }))
    assert.same(log, { "field", "root" })
  end)
end)

describe("hydronium_ink input -- focus binding", function()
  --- A focusable field. Focus decides which of several equally-deep fields is
  --- live; depth decides how specific a handler is. They are orthogonal.
  local function Field(log, name, autoFocus)
    return function()
      local focus = hooks.useFocus({ id = name, autoFocus = autoFocus })
      hooks.useInput(function(_, _, evt)
        log[#log + 1] = name
        evt.stop()
      end, { focusId = focus.id })
      return function() return H.h(ink.Text, {}, name) end
    end
  end

  it("offers the event only to the focused field", function()
    local log = {}
    run(H.h(ink.Box, {},
      H.h(Field(log, "alpha", true)),
      H.h(Field(log, "beta", false)),
      H.h(Recorder(log, "root"))))
    assert.same(log, { "alpha" })
  end)

  it("falls through when nothing is focused", function()
    local log = {}
    run(H.h(ink.Box, {},
      H.h(Field(log, "alpha", false)),
      H.h(Recorder(log, "root"))))
    assert.same(log, { "root" }, "an unfocused field must not swallow the key")
  end)

  it("follows the focus ring", function()
    local log = {}
    local element = H.h(ink.Box, {},
      H.h(Field(log, "alpha", true)),
      H.h(Field(log, "beta", false)))
    local s = session.create(element, { writeFn = function() end, columns = 40, rows = 8 })
    s:write("x")
    -- Tab moves focus and is consumed by the move: the newly focused field
    -- must not also receive the Tab, or it would type one into itself.
    s:write("\t")
    s:write("x")
    s:close()
    assert.same(log, { "alpha", "beta" })
  end)
end)
