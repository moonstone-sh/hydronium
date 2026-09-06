--[[
  Hydronium DOM Intrinsic Descriptor Specification
  Tests for Task 1:
  - Runtime descriptor tables with $$typeof = symbols.INTRINSIC
  - Plain Lua __call invocation d.button({ class = "btn" }, "Hello")
  - createElement(d.button, ...) in src/hydronium/core/element.lua
  - SSR render_to_string with <d.button> and <d.input /> (void tag without slash)
  - Reconciler diffing and host node reuse with descriptor tables in TestHost
--]]

local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert

local H = require("hydronium")
local symbols = H.symbols
local d = require("hydronium.dom")

describe("Core: DOM Descriptor Tables & Lexical Tags", function()

  describe("Descriptor Table Structure & Invariant", function()
    it("verifies d.button is a runtime descriptor table with $$typeof = symbols.INTRINSIC", function()
      assert.is_table(d.button)
      assert.equal(d.button["$$typeof"], symbols.INTRINSIC)
      assert.equal(d.button._typeof, symbols.INTRINSIC)
      assert.equal(d.button.tag, "button")
      assert.truthy(tostring(d.button):find("button"))
    end)

    it("verifies other standard HTML/SVG descriptors have $$typeof = symbols.INTRINSIC", function()
      local tags = { "div", "span", "input", "h1", "p", "a", "form", "svg" }
      for _, tag in ipairs(tags) do
        assert.is_table(d[tag])
        assert.equal(d[tag]["$$typeof"], symbols.INTRINSIC)
        assert.equal(d[tag].tag, tag)
      end
    end)

    it("creates descriptors on-demand for custom elements", function()
      local custom = d["custom-element"]
      assert.is_table(custom)
      assert.equal(custom["$$typeof"], symbols.INTRINSIC)
      assert.equal(custom.tag, "custom-element")
    end)
  end)

  describe("Plain Lua Metamethod __call Invocation", function()
    it("invokes d.button({ class = 'btn' }, 'Hello') in plain Lua", function()
      local vnode = d.button({ class = "btn", id = "submit-btn" }, "Hello")
      assert.is_table(vnode)
      assert.equal(vnode._typeof, symbols.VNODE)
      assert.equal(vnode.kind, symbols.ELEMENT)
      assert.equal(vnode.props.class, "btn")
      assert.equal(vnode.props.id, "submit-btn")
      assert.equal(#vnode.children, 1)
      assert.equal(vnode.children[1].text, "Hello")
    end)

    it("invokes d.input({ type = 'text', value = 'hydronium' })", function()
      local vnode = d.input({ type = "text", value = "hydronium" })
      assert.is_table(vnode)
      assert.equal(vnode._typeof, symbols.VNODE)
      assert.equal(vnode.kind, symbols.ELEMENT)
      assert.equal(vnode.props.type, "text")
      assert.equal(vnode.props.value, "hydronium")
      assert.equal(#vnode.children, 0)
    end)
  end)

  describe("createElement with Descriptor Tables", function()
    it("creates VNode via createElement(d.button, ...)", function()
      local vnode = H.createElement(d.button, { disabled = true }, "Save")
      assert.is_table(vnode)
      assert.equal(vnode._typeof, symbols.VNODE)
      assert.equal(vnode.kind, symbols.ELEMENT)
      assert.equal(vnode.props.disabled, true)
      assert.equal(#vnode.children, 1)
      assert.equal(vnode.children[1].text, "Save")
    end)

    it("creates nested VNode tree with descriptor tables", function()
      local tree = H.createElement(d.div, { class = "wrapper" },
        H.createElement(d.h1, nil, "Title"),
        H.createElement(d.button, { class = "btn" }, "Action")
      )
      assert.equal(tree.kind, symbols.ELEMENT)
      assert.equal(#tree.children, 2)
      assert.equal(tree.children[1].kind, symbols.ELEMENT)
      assert.equal(tree.children[2].kind, symbols.ELEMENT)
    end)
  end)

  describe("SSR render_to_string with Descriptors", function()
    it("renders <d.button>Save</d.button> to <button>Save</button>", function()
      local vnode = d.button(nil, "Save")
      local html_out = H.render_to_string(vnode)
      assert.equal(html_out, "<button>Save</button>")
    end)

    it("renders <d.button class='btn'>Save</d.button> to <button class='btn'>Save</button>", function()
      local vnode = d.button({ class = "btn" }, "Save")
      local html_out = H.render_to_string(vnode)
      assert.equal(html_out, '<button class="btn">Save</button>')
    end)

    it("renders <d.input /> to <input> (void tag without slash)", function()
      local vnode = d.input()
      local html_out = H.render_to_string(vnode)
      assert.equal(html_out, "<input>")
      assert.falsy(html_out:find("/>"))
      assert.falsy(html_out:find("</input>"))
    end)

    it("renders <d.input disabled /> producing void element with boolean attribute", function()
      local vnode = d.input({ disabled = true })
      local html_out = H.render_to_string(vnode)
      assert.equal(html_out, "<input disabled>")
    end)

    it("renders nested components and descriptor elements", function()
      local vnode = d.div({ class = "container" },
        d.h1(nil, "Hello Hydronium"),
        d.input({ disabled = true }),
        d.button({ disabled = true }, "Submit")
      )
      local html_out = H.render_to_string(vnode)
      assert.equal(html_out, '<div class="container"><h1>Hello Hydronium</h1><input disabled><button disabled>Submit</button></div>')
    end)
  end)

  describe("Reconciler Diffing with Descriptor Tables in TestHost", function()
    it("mounts and updates descriptor elements preserving host node identity", function()
      local root = H.create_test_root()

      -- Initial render
      root:render(d.div({ id = "root-div" },
        d.button({ id = "btn-1", class = "btn-default" }, "Click 1"),
        d.button({ id = "btn-2", class = "btn-default" }, "Click 2")
      ))

      local btn1_before = root:find({ id = "btn-1" })
      local btn2_before = root:find({ id = "btn-2" })
      assert.is_not_nil(btn1_before)
      assert.is_not_nil(btn2_before)
      assert.equal(btn1_before.props.class, "btn-default")

      -- Update props with descriptor elements
      root:update(d.div({ id = "root-div" },
        d.button({ id = "btn-1", class = "btn-active" }, "Updated 1"),
        d.button({ id = "btn-2", class = "btn-disabled" }, "Updated 2")
      ))

      local btn1_after = root:find({ id = "btn-1" })
      local btn2_after = root:find({ id = "btn-2" })

      -- Identity preserved
      assert.equal(btn1_before.id, btn1_after.id)
      assert.equal(btn2_before.id, btn2_after.id)
      assert.equal(btn1_after.props.class, "btn-active")
      assert.equal(btn2_after.props.class, "btn-disabled")
    end)

    it("performs keyed reordering of descriptor elements", function()
      local root = H.create_test_root()

      root:render(d.ul(nil,
        d.li({ key = "item-a", id = "a" }, "Item A"),
        d.li({ key = "item-b", id = "b" }, "Item B"),
        d.li({ key = "item-c", id = "c" }, "Item C")
      ))

      local node_a = root:find({ id = "a" })
      local node_b = root:find({ id = "b" })
      local node_c = root:find({ id = "c" })

      -- Reverse order
      root:update(d.ul(nil,
        d.li({ key = "item-c", id = "c" }, "Item C"),
        d.li({ key = "item-b", id = "b" }, "Item B"),
        d.li({ key = "item-a", id = "a" }, "Item A")
      ))

      local node_a_new = root:find({ id = "a" })
      local node_b_new = root:find({ id = "b" })
      local node_c_new = root:find({ id = "c" })

      -- Host node IDs are preserved across reorder
      assert.equal(node_a.id, node_a_new.id)
      assert.equal(node_b.id, node_b_new.id)
      assert.equal(node_c.id, node_c_new.id)

      -- Verify new DOM order
      local ul = root:find("ul")
      assert.equal(ul.children[1].id, node_c.id)
      assert.equal(ul.children[2].id, node_b.id)
      assert.equal(ul.children[3].id, node_a.id)
    end)
  end)
end)
