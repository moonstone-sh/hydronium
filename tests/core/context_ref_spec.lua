local h = require("tests.runner")
local H = require("hydronium")

local describe, it = h.describe, h.it
local assert = h.assert

describe("Core: Context & Refs", function()

  describe("Context default values", function()
    it("returns default value when no Provider exists in the tree", function()
      local ThemeContext = H.create_context("default_theme")

      local function ConsumerComp()
        local theme = H.use_context(ThemeContext)
        return H.h("span", nil, theme)
      end

      local root = H.create_test_root()
      root:render(H.h(ConsumerComp))

      assert.equal(root:text(), "default_theme")
    end)
  end)

  describe("Context propagation", function()
    it("propagates context value down deep component subtrees", function()
      local UserContext = H.create_context(nil)

      local function GrandChild()
        local user = H.use_context(UserContext)
        return H.h("div", { id = "user" }, user and user.name or "Anonymous")
      end

      local function Intermediate()
        return H.h("section", nil, H.h("div", nil, H.h(GrandChild)))
      end

      local function App()
        return H.h(UserContext.Provider, { value = { name = "Alice", role = "Admin" } },
          H.h(Intermediate)
        )
      end

      local root = H.create_test_root()
      root:render(H.h(App))

      assert.equal(root:text(), "Alice")
    end)

    it("allows nested providers to override ancestor context", function()
      local LevelContext = H.create_context(0)

      local function Reader(props)
        local lvl = H.use_context(LevelContext)
        return H.h("span", { id = props.id }, tostring(lvl))
      end

      local function App()
        return H.h(LevelContext.Provider, { value = 1 },
          H.h(Reader, { id = "outer" }),
          H.h(LevelContext.Provider, { value = 2 },
            H.h(Reader, { id = "inner" })
          )
        )
      end

      local root = H.create_test_root()
      root:render(H.h(App))

      local outerNode = root:find({ id = "outer" })
      local innerNode = root:find({ id = "inner" })

      assert.equal(outerNode.children[1].text, "1")
      assert.equal(innerNode.children[1].text, "2")
    end)
  end)

  describe("Provider updates", function()
    it("updates consuming components when provider value changes via signal", function()
      local CountContext = H.create_context(0)

      local function Consumer()
        local c = H.use_context(CountContext)
        return H.h("p", { id = "display" }, "Val: " .. tostring(c))
      end

      local currentCount, setCount = H.signal(10)

      local function App()
        return H.h(CountContext.Provider, { value = currentCount() },
          H.h(Consumer)
        )
      end

      local root = H.create_test_root()
      root:render(H.h(App))

      assert.equal(root:text(), "Val: 10")

      H.act(function()
        setCount(25)
      end)

      assert.equal(root:text(), "Val: 25")
    end)

    it("updates consuming components when provider updates via root:update", function()
      local StatusContext = H.create_context("offline")

      local function StatusBadge()
        local status = H.use_context(StatusContext)
        return H.h("span", nil, status)
      end

      local root = H.create_test_root()
      root:render(H.h(StatusContext.Provider, { value = "online" },
        H.h(StatusBadge)
      ))
      assert.equal(root:text(), "online")

      root:update(H.h(StatusContext.Provider, { value = "busy" },
        H.h(StatusBadge)
      ))
      assert.equal(root:text(), "busy")
    end)
  end)

  describe("Object refs and callback refs", function()
    it("binds object ref on mount and clears on unmount", function()
      local nodeRef = H.create_ref()
      assert.is_table(nodeRef)
      assert.is_nil(nodeRef.current)

      local root = H.create_test_root()
      root:render(H.h("input", { ref = nodeRef, id = "inp", value = "test" }))

      assert.is_not_nil(nodeRef.current)
      assert.equal(nodeRef.current.tag, "input")
      assert.equal(nodeRef.current.props.id, "inp")

      root:unmount()
      assert.is_nil(nodeRef.current)
    end)

    it("executes callback ref with node on mount and nil on unmount", function()
      local lifecycle = {}

      local function onRef(node)
        if node then
          table.insert(lifecycle, { action = "mount", tag = node.tag, id = node.props.id })
        else
          table.insert(lifecycle, { action = "unmount" })
        end
      end

      local root = H.create_test_root()
      root:render(H.h("div", { ref = onRef, id = "box" }))

      assert.equal(#lifecycle, 1)
      assert.equal(lifecycle[1].action, "mount")
      assert.equal(lifecycle[1].tag, "div")
      assert.equal(lifecycle[1].id, "box")

      root:unmount()

      assert.equal(#lifecycle, 2)
      assert.equal(lifecycle[2].action, "unmount")
    end)

    it("detaches old callback ref and attaches new callback ref on change", function()
      local log = {}
      local ref1 = function(n) table.insert(log, n and "ref1:mount" or "ref1:unmount") end
      local ref2 = function(n) table.insert(log, n and "ref2:mount" or "ref2:unmount") end

      local root = H.create_test_root()
      root:render(H.h("span", { ref = ref1 }))
      assert.same(log, { "ref1:mount" })

      root:update(H.h("span", { ref = ref2 }))
      assert.same(log, { "ref1:mount", "ref1:unmount", "ref2:mount" })

      root:unmount()
      assert.same(log, { "ref1:mount", "ref1:unmount", "ref2:mount", "ref2:unmount" })
    end)
  end)

  describe("Refs on components (ref is an ordinary prop, not auto-forwarded)", function()
    it("reaches a stateless component as props.ref, for the author to forward manually", function()
      local nodeRef = H.create_ref()

      local function Fancy(props)
        return H.h("button", { ref = props.ref, id = "fancy-btn" }, "click")
      end

      local root = H.create_test_root()
      root:render(H.h(Fancy, { ref = nodeRef }))

      assert.is_not_nil(nodeRef.current)
      assert.equal(nodeRef.current.tag, "button")
      assert.equal(nodeRef.current.props.id, "fancy-btn")

      root:unmount()
      assert.is_nil(nodeRef.current)
    end)

    it("reaches a setup-shape component (returns a render function) as props.ref too", function()
      local nodeRef = H.create_ref()

      local function Fancy(props, scope)
        return function()
          return H.h("input", { ref = props.ref, id = "fancy-input" })
        end
      end

      local root = H.create_test_root()
      root:render(H.h(Fancy, { ref = nodeRef }))

      assert.is_not_nil(nodeRef.current)
      assert.equal(nodeRef.current.tag, "input")

      root:unmount()
      assert.is_nil(nodeRef.current)
    end)

    it("lets a component expose a synthesized imperative handle instead of a real host node", function()
      local handleRef = H.create_ref()

      local function Fancy(props)
        if props.ref then
          props.ref.current = {
            focus = function() return "focused" end,
          }
        end
        return H.h("div", nil, "fancy")
      end

      local root = H.create_test_root()
      root:render(H.h(Fancy, { ref = handleRef }))

      assert.is_not_nil(handleRef.current)
      assert.equal(handleRef.current.focus(), "focused")
    end)

    it("does not error when no ref is passed to a component -- props.ref is simply nil", function()
      local function Plain(props)
        assert.is_nil(props.ref)
        return H.h("div", nil, "plain")
      end

      local root = H.create_test_root()
      local ok = pcall(function()
        root:render(H.h(Plain, {}))
      end)
      assert.truthy(ok)
    end)
  end)

end)
