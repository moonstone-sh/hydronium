--[[
  Layered input dispatch: order, consumption and focus gating, driven through
  a real session with real components.
--]]

local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert

local H = require("hydronium")
local ink = require("hydronium_ink")
local hooks = require("hydronium_ink.hooks")
local session = require("hydronium_ink.session")

--- Builds a component that records into `log` on every key it receives.
local function Recorder(log, name, opts)
  return function()
    hooks.useInput(function(_, _, evt)
      log[#log + 1] = name
      if opts and opts.consume then evt.stop() end
    end, { layer = opts and opts.layer, focusId = opts and opts.focusId })
    return function() return H.h(ink.Text, {}, name) end
  end
end

local function run(build)
  local log = {}
  local element = build(log)
  local s = session.create(element, { writeFn = function() end, columns = 40, rows = 6 })
  s:write("x")
  s:close()
  return log
end

describe("hydronium_ink input layers -- ordering", function()
  it("dispatches highest layer first regardless of mount order", function()
    local log = run(function(l)
      -- Mounted low-to-high on purpose: order must come from the layer, not
      -- from which component happened to register first.
      return H.h(ink.Box, {},
        H.h(Recorder(l, "global", { layer = "global" })),
        H.h(Recorder(l, "view", { layer = "view" })),
        H.h(Recorder(l, "overlay", { layer = "overlay" })))
    end)
    assert.same(log, { "overlay", "view", "global" })
  end)

  it("preserves registration order within one layer", function()
    local log = run(function(l)
      return H.h(ink.Box, {},
        H.h(Recorder(l, "first", { layer = "view" })),
        H.h(Recorder(l, "second", { layer = "view" })))
    end)
    assert.same(log, { "first", "second" })
  end)

  it("defaults an unspecified layer to view", function()
    local log = run(function(l)
      return H.h(ink.Box, {},
        H.h(Recorder(l, "plain")),
        H.h(Recorder(l, "overlay", { layer = "overlay" })),
        H.h(Recorder(l, "global", { layer = "global" })))
    end)
    assert.same(log, { "overlay", "plain", "global" })
  end)
end)

describe("hydronium_ink input layers -- consumption", function()
  it("stops lower layers once a handler consumes", function()
    local log = run(function(l)
      return H.h(ink.Box, {},
        H.h(Recorder(l, "overlay", { layer = "overlay", consume = true })),
        H.h(Recorder(l, "view", { layer = "view" })),
        H.h(Recorder(l, "global", { layer = "global" })))
    end)
    assert.same(log, { "overlay" }, "a consumed key must not reach lower layers")
  end)

  it("does not consume merely because a handler ran", function()
    -- Consumption is explicit. A handler that simply returns must not stop
    -- propagation -- returning a truthy value by accident is exactly the
    -- silent failure an implicit protocol would cause.
    local log = run(function(l)
      return H.h(ink.Box, {},
        H.h(Recorder(l, "view", { layer = "view" })),
        H.h(Recorder(l, "global", { layer = "global" })))
    end)
    assert.same(log, { "view", "global" })
  end)
end)

describe("hydronium_ink input layers -- focus gating", function()
  --- Two focusable fields; only the focused one may receive keys.
  local function Field(log, name, autoFocus)
    return function()
      local focus = hooks.useFocus({ id = name, autoFocus = autoFocus })
      hooks.useInput(function(_, _, evt)
        log[#log + 1] = name
        evt.stop()
      end, { layer = "focus", focusId = focus.id })
      return function() return H.h(ink.Text, {}, name) end
    end
  end

  it("routes keys only to the focused component", function()
    local log = run(function(l)
      return H.h(ink.Box, {},
        H.h(Field(l, "alpha", true)),
        H.h(Field(l, "beta", false)),
        H.h(Recorder(l, "global", { layer = "global" })))
    end)
    assert.same(log, { "alpha" }, "only the focused field may see the key")
  end)

  it("falls through to lower layers when nothing is focused", function()
    local log = run(function(l)
      return H.h(ink.Box, {},
        H.h(Field(l, "alpha", false)),
        H.h(Recorder(l, "global", { layer = "global" })))
    end)
    assert.same(log, { "global" },
      "an unfocused focus-layer handler must not swallow the key")
  end)

  it("follows focus when it moves", function()
    local log = {}
    local element = H.h(ink.Box, {},
      H.h(Field(log, "alpha", true)),
      H.h(Field(log, "beta", false)))
    local s = session.create(element, { writeFn = function() end, columns = 40, rows = 6 })
    s:write("x")
    -- Tab moves focus to the next registered field.
    s:write("\t")
    s:write("x")
    s:close()
    -- Two entries, not three: the Tab that moved focus is consumed by the
    -- focus ring and never reaches the newly-focused field, which would
    -- otherwise have a tab character typed into it on arrival.
    assert.same(log, { "alpha", "beta" }, "input routing must follow the focus ring")
  end)
end)
