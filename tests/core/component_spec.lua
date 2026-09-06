local h = require("tests.runner")
local H = require("hydronium")

local describe, it = h.describe, h.it
local assert = h.assert

describe("Core: Components & Scope Lifecycle", function()

  describe("Setup-once / render-many (closure components)", function()
    it("runs setup function once and render function on subsequent updates", function()
      local setupCount = 0
      local renderCount = 0
      local count, setCount = H.signal(1)

      local function Counter(props, scope)
        setupCount = setupCount + 1

        return function()
          renderCount = renderCount + 1
          return H.h("div", { id = "counter" }, "Count: " .. tostring(count()))
        end
      end

      local root = H.create_test_root()
      root:render(H.h(Counter))

      assert.equal(setupCount, 1)
      assert.equal(renderCount, 1)
      assert.equal(root:text(), "Count: 1")

      -- Update reactive signal
      H.act(function()
        setCount(2)
      end)

      -- Setup must NOT run again; render function runs
      assert.equal(setupCount, 1)
      assert.equal(renderCount, 2)
      assert.equal(root:text(), "Count: 2")

      H.act(function()
        setCount(3)
      end)

      assert.equal(setupCount, 1)
      assert.equal(renderCount, 3)
      assert.equal(root:text(), "Count: 3")
    end)
  end)

  describe("Pure functional components", function()
    it("renders direct element return and updates on prop changes", function()
      local renderRuns = 0

      local function Greeting(props)
        renderRuns = renderRuns + 1
        return H.h("h1", { class = "title" }, "Hello " .. tostring(props.name))
      end

      local root = H.create_test_root()
      root:render(H.h(Greeting, { name = "Alice" }))

      assert.equal(renderRuns, 1)
      assert.equal(root:text(), "Hello Alice")

      root:update(H.h(Greeting, { name = "Bob" }))

      assert.equal(renderRuns, 2)
      assert.equal(root:text(), "Hello Bob")
    end)
  end)

  describe("Scope ownership", function()
    it("creates hierarchical parent-child scope relationships", function()
      local capturedParentScope = nil
      local capturedChildScope = nil

      local function Child(props, scope)
        capturedChildScope = scope
        return H.h("span", nil, "child")
      end

      local function Parent(props, scope)
        capturedParentScope = scope
        return H.h("div", nil, H.h(Child))
      end

      local root = H.create_test_root()
      root:render(H.h(Parent))

      assert.is_not_nil(capturedParentScope)
      assert.is_not_nil(capturedChildScope)
      assert.equal(capturedChildScope.parent, capturedParentScope)

      -- Parent owns child in its children list
      local found = false
      for _, c in ipairs(capturedParentScope.children) do
        if c == capturedChildScope then
          found = true
          break
        end
      end
      assert.truthy(found)
    end)
  end)

  describe("scope:defer LIFO unwinding", function()
    it("unwinds deferred cleanups in reverse (LIFO) order on unmount", function()
      local order = {}

      local function DisposableComp(props, scope)
        scope:defer(function() table.insert(order, "first_registered") end)
        scope:defer(function() table.insert(order, "second_registered") end)
        scope:defer(function() table.insert(order, "third_registered") end)
        return H.h("div", nil, "content")
      end

      local root = H.create_test_root()
      root:render(H.h(DisposableComp))

      assert.same(order, {})

      root:unmount()

      assert.same(order, {
        "third_registered",
        "second_registered",
        "first_registered"
      })
    end)
  end)

  describe("Child-first scope disposal", function()
    it("disposes child scopes before disposing parent scope", function()
      local disposalLog = {}

      local function GrandChild(props, scope)
        scope:defer(function()
          table.insert(disposalLog, "grandchild_cleanup")
        end)
        return H.h("span", nil, "grandchild")
      end

      local function Child(props, scope)
        scope:defer(function()
          table.insert(disposalLog, "child_cleanup")
        end)
        return H.h("div", nil, H.h(GrandChild))
      end

      local function Parent(props, scope)
        scope:defer(function()
          table.insert(disposalLog, "parent_cleanup")
        end)
        return H.h("div", nil, H.h(Child))
      end

      local root = H.create_test_root()
      root:render(H.h(Parent))
      root:unmount()

      assert.same(disposalLog, {
        "grandchild_cleanup",
        "child_cleanup",
        "parent_cleanup"
      })
    end)
  end)

  describe("scope:id deterministic IDs", function()
    it("generates deterministic IDs that remain stable across re-renders", function()
      local idA_runs = {}
      local idB_runs = {}
      local count, setCount = H.signal(0)

      local function FormInput(props, scope)
        return function()
          local inputId = scope:id("input")
          local descId = scope:id("desc")
          table.insert(idA_runs, inputId)
          table.insert(idB_runs, descId)
          return H.h("div", { id = inputId, ["aria-describedby"] = descId }, count())
        end
      end

      local root = H.create_test_root()
      root:render(H.h(FormInput))

      assert.equal(#idA_runs, 1)
      assert.equal(#idB_runs, 1)

      local firstInputId = idA_runs[1]
      local firstDescId = idB_runs[1]

      assert.is_string(firstInputId)
      assert.is_string(firstDescId)
      assert.not_equal(firstInputId, firstDescId)

      -- Trigger re-render
      H.act(function()
        setCount(1)
      end)

      assert.equal(#idA_runs, 2)
      assert.equal(#idB_runs, 2)
      -- Generated IDs must match exactly across re-renders
      assert.equal(idA_runs[2], firstInputId)
      assert.equal(idB_runs[2], firstDescId)

      -- Another re-render
      H.act(function()
        setCount(2)
      end)

      assert.equal(#idA_runs, 3)
      assert.equal(idA_runs[3], firstInputId)
      assert.equal(idB_runs[3], firstDescId)
    end)

    it("assigns distinct sequence IDs to separate scopes", function()
      local id1 = nil
      local id2 = nil

      local function Comp1(props, scope)
        id1 = scope:id("field")
        return H.h("div")
      end

      local function Comp2(props, scope)
        id2 = scope:id("field")
        return H.h("div")
      end

      local root = H.create_test_root()
      root:render(H.h("div", nil, H.h(Comp1), H.h(Comp2)))

      assert.is_string(id1)
      assert.is_string(id2)
      assert.not_equal(id1, id2)
    end)
  end)

end)
