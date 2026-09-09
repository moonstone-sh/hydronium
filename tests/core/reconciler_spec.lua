local h = require("tests.runner")
local H = require("hydronium")

local describe, it = h.describe, h.it
local assert = h.assert

describe("Core: Reconciler & Child Diffing", function()

  describe("Keyed child diffing & host node reuse", function()
    it("preserves host node identity when reordering items", function()
      local root = H.create_test_root()

      root:render(H.h("ul", nil,
        H.h("li", { key = "a", id = "node_a" }, "A"),
        H.h("li", { key = "b", id = "node_b" }, "B")
      ))

      local hostA1 = root:find({ id = "node_a" })
      local hostB1 = root:find({ id = "node_b" })
      assert.is_not_nil(hostA1)
      assert.is_not_nil(hostB1)

      -- Swap order
      root:update(H.h("ul", nil,
        H.h("li", { key = "b", id = "node_b" }, "B"),
        H.h("li", { key = "a", id = "node_a" }, "A")
      ))

      local hostA2 = root:find({ id = "node_a" })
      local hostB2 = root:find({ id = "node_b" })

      -- Host node instances MUST be reused (identity preserved)
      assert.equal(hostA1.id, hostA2.id)
      assert.equal(hostB1.id, hostB2.id)

      -- Host DOM order must reflect swap
      local ul = root:find("ul")
      assert.equal(ul.children[1].id, hostB1.id)
      assert.equal(ul.children[2].id, hostA1.id)
    end)

    it("handles keyed child insertion (head, middle, tail)", function()
      local root = H.create_test_root()

      root:render(H.h("div", nil,
        H.h("span", { key = "b", id = "B" }, "B")
      ))
      assert.equal(root:text(), "B")

      -- Insert at head and tail
      root:update(H.h("div", nil,
        H.h("span", { key = "a", id = "A" }, "A"),
        H.h("span", { key = "b", id = "B" }, "B"),
        H.h("span", { key = "d", id = "D" }, "D")
      ))
      assert.equal(root:text(), "ABD")

      -- Insert in middle
      root:update(H.h("div", nil,
        H.h("span", { key = "a", id = "A" }, "A"),
        H.h("span", { key = "b", id = "B" }, "B"),
        H.h("span", { key = "c", id = "C" }, "C"),
        H.h("span", { key = "d", id = "D" }, "D")
      ))
      assert.equal(root:text(), "ABCD")
    end)

    it("handles keyed child removal (head, middle, tail)", function()
      local root = H.create_test_root()

      root:render(H.h("div", nil,
        H.h("span", { key = "a" }, "A"),
        H.h("span", { key = "b" }, "B"),
        H.h("span", { key = "c" }, "C"),
        H.h("span", { key = "d" }, "D")
      ))
      assert.equal(root:text(), "ABCD")

      -- Remove head ("a") and tail ("d")
      root:update(H.h("div", nil,
        H.h("span", { key = "b" }, "B"),
        H.h("span", { key = "c" }, "C")
      ))
      assert.equal(root:text(), "BC")

      -- Remove middle ("b")
      root:update(H.h("div", nil,
        H.h("span", { key = "c" }, "C")
      ))
      assert.equal(root:text(), "C")

      -- Remove all
      root:update(H.h("div", nil))
      assert.equal(root:text(), "")
    end)

    it("handles keyed reversing", function()
      local root = H.create_test_root()

      root:render(H.h("div", nil,
        H.h("span", { key = "1", id = "n1" }, "1"),
        H.h("span", { key = "2", id = "n2" }, "2"),
        H.h("span", { key = "3", id = "n3" }, "3"),
        H.h("span", { key = "4", id = "n4" }, "4"),
        H.h("span", { key = "5", id = "n5" }, "5")
      ))
      assert.equal(root:text(), "12345")

      local n1 = root:find({ id = "n1" })
      local n5 = root:find({ id = "n5" })

      root:update(H.h("div", nil,
        H.h("span", { key = "5", id = "n5" }, "5"),
        H.h("span", { key = "4", id = "n4" }, "4"),
        H.h("span", { key = "3", id = "n3" }, "3"),
        H.h("span", { key = "2", id = "n2" }, "2"),
        H.h("span", { key = "1", id = "n1" }, "1")
      ))
      assert.equal(root:text(), "54321")

      -- Confirm node instances were reused
      assert.equal(root:find({ id = "n1" }).id, n1.id)
      assert.equal(root:find({ id = "n5" }).id, n5.id)
    end)

    it("handles mixed complex operations (inserts, removals, reorders)", function()
      local root = H.create_test_root()

      root:render(H.h("div", nil,
        H.h("span", { key = "a", id = "A" }, "A"),
        H.h("span", { key = "b", id = "B" }, "B"),
        H.h("span", { key = "c", id = "C" }, "C"),
        H.h("span", { key = "d", id = "D" }, "D")
      ))
      assert.equal(root:text(), "ABCD")

      -- b and d removed; x and y added; c moved before a
      root:update(H.h("div", nil,
        H.h("span", { key = "x", id = "X" }, "X"),
        H.h("span", { key = "c", id = "C" }, "C"),
        H.h("span", { key = "a", id = "A" }, "A"),
        H.h("span", { key = "y", id = "Y" }, "Y")
      ))

      assert.equal(root:text(), "XCAY")
      assert.is_nil(root:find({ id = "B" }))
      assert.is_nil(root:find({ id = "D" }))
      assert.is_not_nil(root:find({ id = "X" }))
      assert.is_not_nil(root:find({ id = "Y" }))
    end)
  end)

  describe("Unkeyed diffing", function()
    it("updates existing host node in-place when tag matches", function()
      local root = H.create_test_root()

      root:render(H.h("div", { class = "old" }, "Initial Text"))
      local initialDiv = root:find("div")

      root:update(H.h("div", { class = "new" }, "Updated Text"))
      local updatedDiv = root:find("div")

      assert.equal(initialDiv.id, updatedDiv.id)
      assert.equal(updatedDiv.props.class, "new")
      assert.equal(root:text(), "Updated Text")
    end)

    it("replaces host node when tag differs", function()
      local root = H.create_test_root()

      root:render(H.h("div", nil, H.h("p", { id = "para" }, "Paragraph")))
      local oldP = root:find({ id = "para" })

      root:update(H.h("div", nil, H.h("span", { id = "span" }, "Span")))
      local newSpan = root:find({ id = "span" })

      assert.is_nil(root:find({ id = "para" }))
      assert.is_not_nil(newSpan)
      assert.not_equal(oldP.id, newSpan.id)
      assert.equal(root:text(), "Span")
    end)

    it("handles list growth and shrink by index", function()
      local root = H.create_test_root()

      root:render(H.h("div", nil, "one", "two"))
      assert.equal(root:text(), "onetwo")

      -- Grow
      root:update(H.h("div", nil, "one", "two", "three", "four"))
      assert.equal(root:text(), "onetwothreefour")

      -- Shrink
      root:update(H.h("div", nil, "one"))
      assert.equal(root:text(), "one")
    end)
  end)

  describe("Fragment unwrapping", function()
    it("unwraps fragment children directly into host container", function()
      local root = H.create_test_root()

      root:render(H.h("div", { id = "parent" },
        H.h(H.Fragment, nil,
          H.h("span", { id = "c1" }, "First"),
          H.h("span", { id = "c2" }, "Second")
        )
      ))

      local parentNode = root:find({ id = "parent" })
      assert.equal(#parentNode.children, 2)
      assert.equal(parentNode.children[1].props.id, "c1")
      assert.equal(parentNode.children[2].props.id, "c2")
    end)

    it("handles fragment expanding and shrinking", function()
      local root = H.create_test_root()

      root:render(H.h("div", nil,
        H.h(H.Fragment, nil, "A")
      ))
      assert.equal(root:text(), "A")

      root:update(H.h("div", nil,
        H.h(H.Fragment, nil, "A", "B", "C")
      ))
      assert.equal(root:text(), "ABC")

      root:update(H.h("div", nil,
        H.h(H.Fragment, nil, "C")
      ))
      assert.equal(root:text(), "C")
    end)
  end)

  describe("Ref binding and unbinding", function()
    it("binds object ref on commit and unbinds on unmount", function()
      local refObj = H.create_ref()
      local root = H.create_test_root()

      assert.is_nil(refObj.current)

      root:render(H.h("button", { ref = refObj, id = "btn" }, "Click"))
      local btnNode = root:find({ id = "btn" })

      assert.is_not_nil(refObj.current)
      assert.equal(refObj.current.id, btnNode.id)

      root:unmount()
      assert.is_nil(refObj.current)
    end)

    it("invokes callback ref with host node on mount and nil on unmount", function()
      local calls = {}
      local callbackRef = function(node)
        table.insert(calls, node and node.id or nil)
      end

      local root = H.create_test_root()
      root:render(H.h("input", { ref = callbackRef, id = "input" }))

      local inputNode = root:find({ id = "input" })
      assert.same(calls, { inputNode.id })

      root:unmount()
      assert.same(calls, { inputNode.id, nil })
    end)

    it("swaps ref bindings when element ref changes across renders", function()
      local refA = H.create_ref()
      local refB = H.create_ref()

      local root = H.create_test_root()
      root:render(H.h("div", { ref = refA, id = "d" }))

      local divNode = root:find({ id = "d" })
      assert.equal(refA.current.id, divNode.id)
      assert.is_nil(refB.current)

      -- Switch to refB
      root:update(H.h("div", { ref = refB, id = "d" }))

      assert.is_nil(refA.current)
      assert.equal(refB.current.id, divNode.id)
    end)
  end)

  describe("Duplicate key resilience", function()
    it("reconciles sibling elements with duplicate keys without crashing", function()
      local root = H.create_test_root()

      -- Intentionally provide duplicate keys among siblings
      root:render(H.h("ul", nil,
        H.h("li", { key = "dup", id = "item1" }, "First Dup"),
        H.h("li", { key = "dup", id = "item2" }, "Second Dup"),
        H.h("li", { key = "unique", id = "item3" }, "Unique")
      ))

      assert.equal(root:text(), "First DupSecond DupUnique")

      -- Re-render with updated duplicate keys
      root:update(H.h("ul", nil,
        H.h("li", { key = "unique", id = "item3" }, "Unique"),
        H.h("li", { key = "dup", id = "item1" }, "First Dup Updated"),
        H.h("li", { key = "dup", id = "item2" }, "Second Dup Updated")
      ))

      assert.equal(root:text(), "UniqueFirst Dup UpdatedSecond Dup Updated")
    end)
  end)

end)

describe("Fine-grained DOM bindings (mandatory, not opt-in)", function()
  it("a bare signal-accessor child updates the DOM without re-rendering the owning component", function()
    local count, setCount = H.signal(0)
    local renderCount = 0

    local function Counter()
      renderCount = renderCount + 1
      return H.h("div", { id = "count" }, "Count: ", count)
    end

    local root = H.create_test_root()
    root:render(H.h(Counter))

    assert.equal(root:text(), "Count: 0")
    assert.equal(renderCount, 1)

    H.act(function()
      setCount(5)
    end)

    assert.equal(root:text(), "Count: 5")
    -- The DOM updated via the binding effect, not a component re-render.
    assert.equal(renderCount, 1)
  end)

  it("a signal-valued non-event prop updates the DOM attribute without re-rendering the owning component", function()
    local active, setActive = H.signal("idle")
    local renderCount = 0

    local function Box()
      renderCount = renderCount + 1
      return H.h("div", { id = "box", class = active }, "x")
    end

    local root = H.create_test_root()
    root:render(H.h(Box))

    local box = root:find({ id = "box" })
    assert.equal(box.props.class, "idle")
    assert.equal(renderCount, 1)

    H.act(function()
      setActive("busy")
    end)

    box = root:find({ id = "box" })
    assert.equal(box.props.class, "busy")
    assert.equal(renderCount, 1)
  end)

  it("an eagerly-called signal (count()) still goes through the ordinary component re-render path unchanged", function()
    local count, setCount = H.signal(0)
    local renderCount = 0

    local function Counter()
      renderCount = renderCount + 1
      return H.h("div", nil, "Count: " .. tostring(count()))
    end

    local root = H.create_test_root()
    root:render(H.h(Counter))
    assert.equal(root:text(), "Count: 0")

    H.act(function()
      setCount(7)
    end)

    assert.equal(root:text(), "Count: 7")
    assert.equal(renderCount, 2)
  end)

  -- Collects every live binding effect in a mounted tree, so a spec can
  -- assert on the effect's OWN disposal state rather than on a proxy
  -- signal that something else also produces.
  local function collectBindingEffects(vnode, out, depth)
    out = out or {}
    depth = depth or 0
    if depth > 16 then return out end
    local t = type(vnode)
    if t ~= "table" and t ~= "userdata" then return out end
    if vnode._bindingEffect then
      table.insert(out, vnode._bindingEffect)
    end
    local ci = vnode.componentInstance
    if ci and ci.subTree then
      collectBindingEffects(ci.subTree, out, depth + 1)
    end
    local children = vnode.children
    if children then
      local n = #children
      for i = 1, n do
        collectBindingEffects(children[i], out, depth + 1)
      end
    end
    return out
  end

  local function subscriberCount(signal)
    local n = 0
    for _ in pairs(signal._signal.subscribers) do n = n + 1 end
    return n
  end

  -- REGRESSION. The predecessor of this spec unmounted the whole root and
  -- asserted only that a later `setCount` did not raise. That assertion
  -- held whether or not Reconciler:_disposeBindings existed at all:
  -- unmounting the root disposes the owning component's scope, and scope
  -- disposal alone already runs each Effect's deferred dispose. Neutering
  -- _disposeBindings to a no-op left the spec passing -- it verified
  -- nothing about the code it named.
  --
  -- This version unmounts a nested ELEMENT while the owning component --
  -- and therefore its scope -- stays mounted, which is the only situation
  -- in which _disposeBindings is the thing that disposes the binding. All
  -- three assertions below flip when it is stubbed out.
  it("disposes a binding effect when its element unmounts while the owning component stays mounted", function()
    local show, setShow = H.signal(true)
    local value = H.signal("V")

    local function App()
      return function()
        if show() then
          return H.h("div", nil, H.h("span", { id = "s" }, "v=", value))
        end
        return H.h("div", nil)
      end
    end

    local root = H.create_test_root()
    root:render(H.h(App))

    local effects = collectBindingEffects(root:getVNode())
    assert.equal(#effects, 1)
    local binding = effects[1]
    local componentScope = root:getVNode().componentInstance.scope

    assert.falsy(binding.isDisposed)
    assert.equal(subscriberCount(value), 1)
    assert.equal(#componentScope.cleanups, 1)

    H.act(function()
      setShow(false)
    end)

    -- The component is still mounted; only the <span> subtree went away.
    assert.falsy(componentScope.isDisposed)
    -- 1. The effect itself is disposed (not merely unreachable).
    assert.truthy(binding.isDisposed)
    -- 2. It really unsubscribed from the signal.
    assert.equal(subscriberCount(value), 0)
    -- 3. Its scope-cleanup entry was removed, not just left inert.
    assert.equal(#componentScope.cleanups, 0)
  end)

  -- REGRESSION (CRITICAL): passing a signal as a prop to a COMPONENT used
  -- to be silently destroyed. createElement applied the reactive-prop
  -- split for every vnode kind, but only the ELEMENT branches of
  -- mount/hydrate ever call _bindReactiveProps -- so a component received
  -- `props.value` already collapsed to a plain number (calling it threw
  -- "attempt to call a number value"), nothing bound it, and the parent
  -- did not subscribe either because the split's read is untracked. No
  -- error, no warning, no update ever.
  it("passes a signal prop to a component as the live accessor, not a collapsed snapshot", function()
    local n, setN = H.signal(1)
    local seen = nil

    local function Child(props)
      seen = props.value
      return H.h("span", { id = "child" }, "n=", props.value)
    end

    local function Parent()
      return H.h("div", nil, H.h(Child, { value = n }))
    end

    local root = H.create_test_root()
    root:render(H.h(Parent))

    -- The accessor arrives intact and is callable.
    assert.is_not_nil(seen)
    assert.equal(type(seen), "table")
    local ok, current = pcall(function() return seen() end)
    assert.truthy(ok)
    assert.equal(current, 1)

    -- And it is genuinely reactive where the child chose to read it.
    assert.equal(root:text(), "n=1")
    H.act(function()
      setN(42)
    end)
    assert.equal(root:text(), "n=42")
  end)

  -- REGRESSION (CRITICAL): ComponentInstance:refresh (HMR) disposes the
  -- old scope BEFORE reconciling. Getter identity is unchanged across a
  -- refresh for a stable accessor, so the TEXT branch used to carry the
  -- already-disposed effect onto the new vnode and skip the plain
  -- commitTextUpdate fallback too -- freezing that text node forever
  -- after a single hot reload.
  it("rebinds instead of carrying a disposed effect across an HMR refresh", function()
    local count, setCount = H.signal(1)
    local defA = function()
      return function() return H.h("div", nil, "n=", count) end
    end

    local root = H.create_test_root()
    root:render(H.h(defA))
    assert.equal(root:text(), "n=1")

    H.act(function() setCount(2) end)
    assert.equal(root:text(), "n=2")

    local instance = root:getVNode().componentInstance
    local defB = function()
      return function() return H.h("div", nil, "n=", count) end
    end
    assert.truthy(instance:refresh(defB))

    -- The binding must be live again against the refreshed scope.
    assert.equal(subscriberCount(count), 1)
    H.act(function() setCount(3) end)
    assert.equal(root:text(), "n=3")
  end)

  -- REGRESSION (HIGH): the shared prop snapshot was merged into, never
  -- rebuilt, so a key that disappeared between renders stayed in it. The
  -- ordinary re-render removed the prop correctly, then the next fire of
  -- ANY reactive prop on that element called commitUpdate with the dead
  -- key still present and put it back.
  it("does not resurrect a removed prop when a reactive prop later fires", function()
    local cls, setCls = H.signal("idle")
    local withTitle, setWithTitle = H.signal(true)

    local function Box()
      return function()
        if withTitle() then
          return H.h("div", { id = "box", class = cls, title = "hello" }, "x")
        end
        return H.h("div", { id = "box", class = cls }, "x")
      end
    end

    local root = H.create_test_root()
    root:render(H.h(Box))
    assert.equal(root:find({ id = "box" }).props.title, "hello")

    H.act(function() setWithTitle(false) end)
    assert.is_nil(root:find({ id = "box" }).props.title)

    H.act(function() setCls("busy") end)
    local box = root:find({ id = "box" })
    assert.is_nil(box.props.title)
    assert.equal(box.props.class, "busy")
  end)

  -- REGRESSION (MEDIUM): an inline-closure child is a different function
  -- object on every render, so its binding is disposed and rebuilt each
  -- time. Effect.new appends a dispose closure to the owning scope and
  -- nothing removed it, so the scope accumulated one dead cleanup per
  -- render forever: 1 after mount, 101 after 100 re-renders.
  it("does not accumulate scope cleanups when an inline-closure child rebinds every render", function()
    local tick, setTick = H.signal(0)
    local value = H.signal("V")

    local function App()
      return function()
        tick()
        return H.h("div", nil, function() return value() end)
      end
    end

    local root = H.create_test_root()
    root:render(H.h(App))
    local scope = root:getVNode().componentInstance.scope
    assert.equal(#scope.cleanups, 1)

    for i = 1, 25 do
      H.act(function() setTick(i) end)
    end

    -- One live binding, one cleanup -- not 26.
    assert.equal(#scope.cleanups, 1)
    assert.equal(subscriberCount(value), 1)
  end)

  -- REGRESSION (MEDIUM): flattenChildren used to drop function children
  -- entirely; the binding feature made it call them and tostring() the
  -- result unconditionally, so `{maybeValue}` rendered the literal word
  -- "nil". nil/false/true are exactly the values a STATIC child is
  -- discarded for, so a reactive child holding one must render nothing.
  it("renders an absent reactive value as nothing, not the literal 'nil'", function()
    local value, setValue = H.signal(nil)

    local root = H.create_test_root()
    root:render(H.h("div", nil, "v=", value))
    assert.equal(root:text(), "v=")

    H.act(function() setValue("here") end)
    assert.equal(root:text(), "v=here")

    -- And back again -- the text node stays in place to be re-patched.
    H.act(function() setValue(nil) end)
    assert.equal(root:text(), "v=")

    -- `{cond and x}` yielding false is the same case.
    H.act(function() setValue(false) end)
    assert.equal(root:text(), "v=")
  end)
end)
