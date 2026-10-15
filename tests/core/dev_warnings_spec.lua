local h = require("tests.runner")
local H = require("hydronium")
local dev = require("hydronium.core.dev")

local describe, it = h.describe, h.it
local assert = h.assert

local release_diagnostics

local function capture()
  if release_diagnostics then release_diagnostics() end
  release_diagnostics = require("hydronium.core.dev_diagnostics").install()
  local messages = {}
  dev.reset()
  dev.set_handler(function(text) messages[#messages + 1] = text end)
  return messages
end

describe("Core: development warnings for state created outside setup", function()
  it("warns when a component without setup creates a signal and renders again", function()
    local messages = capture()
    local bump
    local function Card()
      local clicked, setClicked = H.createSignal(false)
      bump = function() setClicked(not clicked()) end
      return H.h("p", nil, tostring(clicked()))
    end
    local root = H.create_test_root()
    root:render(H.h(Card))
    assert.equal(#messages, 0, "the first call is setup: no warning yet")
    H.act(function() bump() end)
    assert.equal(#messages, 1)
    assert.truthy(messages[1]:find("createSignal was called while rendering the component defined at dev_warnings_spec.lua:", 1, true), messages[1])
    assert.truthy(messages[1]:find("return a render function", 1, true), messages[1])
    -- Reported once, however many renders follow.
    H.act(function() bump() end)
    assert.equal(#messages, 1)
    dev.set_handler(nil)
    release_diagnostics()
  end)

  it("warns for a signal or effect created inside a render function", function()
    local messages = capture()
    local count, setCount = H.createSignal(0)
    local function Counter()
      return function()
        local _local = H.createSignal(count())
        H.createEffect(function() end)
        return H.h("p", nil, tostring(count()))
      end
    end
    local root = H.create_test_root()
    root:render(H.h(Counter))
    local kinds = {}
    for _, m in ipairs(messages) do kinds[#kinds + 1] = m:match("%] (%w+) was called") end
    table.sort(kinds)
    assert.equal(table.concat(kinds, ","), "createEffect,createSignal")
    dev.set_handler(nil)
    release_diagnostics()
  end)

  it("stays silent for state created in setup", function()
    local messages = capture()
    local inc
    local function Counter()
      local count, setCount = H.createSignal(0)
      local double = H.createComputed(function() return count() * 2 end)
      H.createEffect(function() local _ = double() end)
      inc = function() setCount(count() + 1) end
      return function() return H.h("p", nil, tostring(double())) end
    end
    local root = H.create_test_root()
    root:render(H.h(Counter))
    H.act(function() inc() end)
    H.act(function() inc() end)
    assert.equal(root:text(), "4")
    assert.equal(#messages, 0, table.concat(messages, "\n"))
    dev.set_handler(nil)
    release_diagnostics()
  end)
end)


describe("Core: optional warning descriptions", function()
  it("loads the warning core without loading debug diagnostics", function()
    local id, diagnostic = "hydronium.core.dev", "hydronium.compat.diagnostics"
    local old_dev, old_diagnostic = package.loaded[id], package.loaded[diagnostic]
    local preload = package.preload[diagnostic]
    package.loaded[id], package.loaded[diagnostic] = nil, nil
    package.preload[diagnostic] = function() error("warnings loaded debug diagnostics") end
    local ok, warning_core = pcall(require, id)
    local untouched = package.loaded[diagnostic] == nil
    package.loaded[id], package.loaded[diagnostic] = old_dev, old_diagnostic
    package.preload[diagnostic] = preload
    assert.truthy(ok, tostring(warning_core))
    assert.truthy(untouched)
    assert.equal(warning_core.describe({}), "<Component>")
  end)

  it("uses useful name-only descriptions without a development adapter", function()
    assert.equal(dev.describe({name="Card",type=function() end}), "<Card>")
    assert.equal(dev.describe({name="Anonymous",type=function() end}), "<Anonymous>")
    assert.equal(dev.describe({type=function() end}), "<Component>")
  end)

  it("releases formatters independently and restores the previous owner", function()
    local first = dev.install_describer(function() return "first" end)
    local second = dev.install_describer(function() return "second" end)
    assert.equal(dev.describe({}), "second")
    assert.equal(first(), true)
    assert.equal(dev.describe({}), "second")
    assert.equal(second(), true)
    assert.equal(dev.describe({}), "<Component>")
    assert.equal(second(), false)
    local previous = dev.install_describer(function() return "previous" end)
    local current = dev.install_describer(function() return nil end)
    assert.equal(dev.describe({}), "<Component>")
    current()
    assert.equal(dev.describe({}), "previous")
    previous()
  end)

  it("the source adapter degrades gracefully without debug support", function()
    local adapter = require("hydronium.core.dev_diagnostics")
    local previous = debug
    debug = nil
    local ok, value = pcall(adapter.describe, {type=function() end})
    debug = previous
    assert.truthy(ok)
    assert.equal(value, nil)
  end)
end)
