local h = require("tests.runner")
local H = require("hydronium")

local describe, it = h.describe, h.it
local assert = h.assert

describe("Core: Element & Normalization", function()

  describe("Element creation", function()
    it("creates element with h and create_element aliases", function()
      local e1 = H.h("div", { id = "main" })
      local e2 = H.create_element("div", { id = "main" })
      local e3 = H.createElement("div", { id = "main" })

      assert.equal(e1.tag, "div")
      assert.equal(e2.tag, "div")
      assert.equal(e3.tag, "div")
      assert.equal(e1.props.id, "main")
    end)

    it("creates element with nil props", function()
      local el = H.h("span")
      assert.equal(el.tag, "span")
      assert.is_table(el.props)
      assert.equal(#el.children, 0)
    end)

    it("creates component elements with functions", function()
      local function MyComp(props) return H.h("div", props) end
      local el = H.h(MyComp, { title = "Hydronium" })
      assert.equal(el.tag, MyComp)
      assert.equal(el.props.title, "Hydronium")
    end)
  end)

  describe("Child normalization", function()
    it("drops false, nil, and true from children", function()
      local el = H.h("div", nil,
        false,
        "valid_1",
        nil,
        true,
        "valid_2",
        false
      )
      assert.equal(#el.children, 2)
      assert.equal(el.children[1].text, "valid_1")
      assert.equal(el.children[2].text, "valid_2")
    end)

    it("converts numbers to strings", function()
      local el = H.h("div", nil, 0, 42, 3.1415, -100)
      assert.equal(#el.children, 4)
      assert.equal(el.children[1].text, "0")
      assert.equal(el.children[2].text, "42")
      assert.equal(el.children[3].text, "3.1415")
      assert.equal(el.children[4].text, "-100")
    end)

    it("recursively flattens deeply nested child arrays", function()
      local el = H.h("ul", nil, {
        "item_1",
        {
          "item_2",
          false,
          {
            "item_3",
            {
              42,
              true,
              nil,
              { "item_5" }
            }
          }
        },
        "item_6"
      })

      assert.equal(#el.children, 6)
      assert.equal(el.children[1].text, "item_1")
      assert.equal(el.children[2].text, "item_2")
      assert.equal(el.children[3].text, "item_3")
      assert.equal(el.children[4].text, "42")
      assert.equal(el.children[5].text, "item_5")
      assert.equal(el.children[6].text, "item_6")
    end)

    it("preserves VNode elements in children", function()
      local child = H.h("span", { class = "inner" }, "text")
      local parent = H.h("div", nil, child)
      assert.equal(#parent.children, 1)
      assert.equal(parent.children[1].tag, "span")
      assert.equal(parent.children[1].props.class, "inner")
    end)

    it("normalizes children passed via props.children when varargs omitted", function()
      local el = H.h("div", {
        children = { "from_props", false, 999, { "nested_props" } }
      })
      assert.equal(#el.children, 3)
      assert.equal(el.children[1].text, "from_props")
      assert.equal(el.children[2].text, "999")
      assert.equal(el.children[3].text, "nested_props")
    end)

    it("varargs children take precedence over props.children", function()
      local el = H.h("div", { children = { "ignored" } }, "preferred")
      assert.equal(#el.children, 1)
      assert.equal(el.children[1].text, "preferred")
    end)
  end)

  describe("Fragments", function()
    it("creates fragment element with Fragment symbol", function()
      local frag = H.h(H.Fragment, nil, "child1", "child2")
      assert.equal(frag.tag, H.Fragment)
      assert.equal(#frag.children, 2)
      assert.equal(frag.children[1].text, "child1")
      assert.equal(frag.children[2].text, "child2")
    end)

    it("supports nested fragments", function()
      local frag = H.h(H.Fragment, nil,
        H.h(H.Fragment, nil, "nested_1"),
        "direct_2"
      )
      assert.equal(#frag.children, 2)
      assert.equal(frag.children[1].tag, H.Fragment)
      assert.equal(frag.children[2].text, "direct_2")
    end)
  end)

  describe("Immutability", function()
    it("prevents mutation of element props", function()
      local el = H.h("div", { id = "frozen", count = 1 })

      assert.has_error(function()
        el.props.id = "modified"
      end, "immutable")

      assert.has_error(function()
        el.props.new_prop = "injected"
      end, "immutable")

      -- Value remains unchanged
      assert.equal(el.props.id, "frozen")
    end)

    it("prevents mutation of element children array", function()
      local el = H.h("div", nil, "child_1")

      assert.has_error(function()
        el.children[1] = "hacked"
      end, "immutable")

      assert.has_error(function()
        table.insert(el.children, "injected")
      end)
    end)

    it("prevents mutation of top-level VNode properties", function()
      local el = H.h("div", { key = "k1" })

      assert.has_error(function()
        el.tag = "span"
      end, "immutable")

      assert.has_error(function()
        el.key = "k2"
      end, "immutable")
    end)
  end)

  describe("Keys & Refs extraction", function()
    it("extracts key from props onto element and removes from props", function()
      local el = H.h("li", { key = "item_1", value = "test" })
      assert.equal(el.key, "item_1")
      assert.equal(el.props.value, "test")
      assert.is_nil(el.props.key)
    end)

    it("extracts ref from props onto element and removes from props", function()
      local my_ref = H.create_ref()
      local el = H.h("input", { ref = my_ref, type = "text" })
      assert.equal(el.ref, my_ref)
      assert.equal(el.props.type, "text")
      assert.is_nil(el.props.ref)
    end)

    it("leaves key and ref as nil when omitted", function()
      local el = H.h("div", { id = "nokey" })
      assert.is_nil(el.key)
      assert.is_nil(el.ref)
    end)
  end)

end)
