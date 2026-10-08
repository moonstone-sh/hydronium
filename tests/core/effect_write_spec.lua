local h = require("tests.runner")
local H = require("hydronium")

local describe, it = h.describe, h.it
local assert = h.assert

describe("Core: signal writes from effects created during render", function()
  it("lets an effect created in setup write a signal on its first run", function()
    local log, setLog = H.createSignal("")
    local function Child(props)
      H.createEffect(function()
        setLog("count " .. props.count())
      end)
      return function() return H.h("span", nil, "child") end
    end
    local count = H.createSignal(1)
    local function App()
      return function()
        return H.h("div", nil, H.h(Child, { count = count }), H.h("p", nil, log))
      end
    end
    local root = H.create_test_root()
    root:render(H.h(App))
    assert.equal(log(), "count 1")
    assert.truthy(root:text():find("count 1", 1, true))
  end)

  it("re-renders a parent that reads a signal its child's effect wrote", function()
    local seen, setSeen = H.createSignal(0)
    local function Child()
      H.createEffect(function() setSeen(function(n) return n + 1 end) end)
      return function() return H.h("span", nil, "x") end
    end
    local renders = 0
    local function App()
      return function()
        renders = renders + 1
        return H.h("div", nil, H.h(Child), H.h("b", nil, tostring(seen())))
      end
    end
    local root = H.create_test_root()
    root:render(H.h(App))
    H.act(function() end)
    assert.equal(seen(), 1)
    assert.equal(root:text(), "x1")
    assert.equal(renders, 2)
  end)

  it("still rejects a write made directly by a render function", function()
    local value, setValue = H.createSignal(0)
    local function Bad()
      return function()
        setValue(value() + 1)
        return H.h("span", nil, "bad")
      end
    end
    local root = H.create_test_root()
    local ok, err = pcall(function() root:render(H.h(Bad)) end)
    assert.equal(ok, false)
    assert.truthy(tostring(err):find("ERR_RENDER_MUTATION", 1, true))
  end)
end)

describe("Core: a mounted tree shows what its effects wrote during setup", function()
  it("flushes after the outermost reconciler mount", function()
    -- A bare reconciler, as the browser mount uses it: no test-root flush.
    local Reconciler = require("hydronium.core.reconciler").Reconciler
    local host = require("hydronium.test.host").createTestHost()
    local label, setLabel = H.createSignal("before")
    local function Child()
      H.createEffect(function() setLabel("after") end)
      return function() return H.h("i", nil, "c") end
    end
    local shown
    local function App()
      return function()
        shown = label()
        return H.h("div", nil, H.h(Child), H.h("b", nil, shown))
      end
    end
    Reconciler.new(host):mount(H.h(App), host.getRoot())
    assert.equal(label(), "after")
    assert.equal(shown, "after")
  end)
end)
