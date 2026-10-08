local h = require("tests.runner")
local H = require("hydronium")
local dev = require("hydronium.core.dev")

local describe, it = h.describe, h.it
local assert = h.assert

local function capture()
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
  end)
end)
