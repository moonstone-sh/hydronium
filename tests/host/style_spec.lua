--[[
  Real tests for the `style` prop: how the browser DOM host applies it,
  how SSR serializes it, and -- the part that actually matters -- that
  those two agree.

  Before this file, `style` had no code path in the DOM host at all: a
  table-valued style prop fell through to the generic attribute setter,
  which handed a raw Lua table to `setAttribute` and produced
  `style="table: 0x55f3..."` in a real browser. SSR, meanwhile, had
  complete and correct style support. The two sides disagreeing is
  exactly the hydration-mismatch class of bug, so the consistency
  assertions at the bottom are the point of this file, not a bonus.

  The bridge here is a real in-memory implementation of the contract
  (following tests/host/dom_spec.lua's own fake-bridge approach), not a
  call recorder: `style_props` below behaves like a real
  CSSStyleDeclaration, so these tests assert on resulting state.
--]]

local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert

local domHostModule = require("hydronium_dom.host.dom")
local style_util = require("hydronium_dom.style")
local html = require("hydronium_dom.server.html")

--- @param opts? table `{ per_property = false }` to simulate a bridge
---   written before per-property style support existed, exercising the
---   documented wholesale-attribute fallback.
local function makeBridge(opts)
  opts = opts or {}
  local per_property = opts.per_property ~= false

  local nextId = 0
  local function newNode(kind)
    nextId = nextId + 1
    return { id = nextId, kind = kind, attrs = {}, style_props = {}, listeners = {}, children = {} }
  end

  local bridge = {}

  function bridge.create_element(tag)
    local n = newNode("element"); n.tag = tag; return n
  end
  function bridge.create_text(text)
    local n = newNode("text"); n.text = text; return n
  end
  function bridge.set_text(node, text) node.text = text end
  function bridge.append_child(parent, child) table.insert(parent.children, child) end
  function bridge.insert_before(parent, child) table.insert(parent.children, child) end
  function bridge.remove_child() end

  function bridge.set_attr(node, key, value)
    node.attrs[key] = value
    -- A real browser parses the `style` attribute into the element's
    -- style declarations; model that so the two paths are comparable.
    if key == "style" then
      node.style_props = {}
      for decl in tostring(value):gmatch("[^;]+") do
        local k, v = decl:match("^%s*([^:]-)%s*:%s*(.-)%s*$")
        if k and v and k ~= "" then node.style_props[k] = v end
      end
    end
  end

  function bridge.remove_attr(node, key)
    node.attrs[key] = nil
    if key == "style" then node.style_props = {} end
  end

  function bridge.set_listener(node, e, fn) node.listeners[e] = fn end
  function bridge.remove_listener(node, e) node.listeners[e] = nil end
  function bridge.first_child(node) return node.children[1] end
  function bridge.next_sibling() return nil end
  function bridge.is_element(node) return node ~= nil and node.kind == "element" end
  function bridge.is_text(node) return node ~= nil and node.kind == "text" end
  function bridge.tag_of(node) return node and node.tag or nil end

  if per_property then
    function bridge.set_style_property(node, name, value)
      node.style_props[name] = value
    end
    function bridge.remove_style_property(node, name)
      node.style_props[name] = nil
    end
  end

  return bridge
end

--- The element's inline style as a sorted, comparable CSS string,
--- however it was applied (per-property or via the attribute).
local function css_of(node)
  local names = {}
  for k in pairs(node.style_props) do table.insert(names, k) end
  table.sort(names)
  local parts = {}
  for _, k in ipairs(names) do table.insert(parts, k .. ": " .. node.style_props[k]) end
  return table.concat(parts, "; ")
end

describe("DOM host: the style prop", function()
  describe("mount (createInstance)", function()
    it("applies a table style per-property, not as a stringified table", function()
      local bridge = makeBridge()
      local host = domHostModule.createDomHost(bridge)
      local el = host.createInstance("div", { style = { color = "red", backgroundColor = "blue" } })

      assert.equal(el.style_props["color"], "red")
      assert.equal(el.style_props["background-color"], "blue")
      -- The original bug: a raw Lua table reaching setAttribute.
      assert.falsy(el.attrs["style"])
    end)

    it("accepts kebab-case keys natively, like Solid", function()
      local bridge = makeBridge()
      local host = domHostModule.createDomHost(bridge)
      local el = host.createInstance("div", { style = { ["background-color"] = "red" } })
      assert.equal(el.style_props["background-color"], "red")
    end)

    it("treats camelCase and kebab-case as the same property", function()
      local bridge = makeBridge()
      local host = domHostModule.createDomHost(bridge)
      local a = host.createInstance("div", { style = { backgroundColor = "red" } })
      local b = host.createInstance("div", { style = { ["background-color"] = "red" } })
      assert.equal(css_of(a), css_of(b))
    end)

    it("appends px to a non-unitless numeric value", function()
      local bridge = makeBridge()
      local host = domHostModule.createDomHost(bridge)
      local el = host.createInstance("div", { style = { width = 200, marginTop = 8 } })
      assert.equal(el.style_props["width"], "200px")
      assert.equal(el.style_props["margin-top"], "8px")
    end)

    it("leaves genuinely unitless numeric values bare", function()
      local bridge = makeBridge()
      local host = domHostModule.createDomHost(bridge)
      local el = host.createInstance("div", { style = { opacity = 0.5, zIndex = 10, lineHeight = 1.5 } })
      assert.equal(el.style_props["opacity"], "0.5")
      assert.equal(el.style_props["z-index"], "10")
      assert.equal(el.style_props["line-height"], "1.5")
    end)

    it("sets a string style as the plain style attribute, verbatim", function()
      local bridge = makeBridge()
      local host = domHostModule.createDomHost(bridge)
      local el = host.createInstance("div", { style = "color: red; margin: 0" })
      assert.equal(el.attrs["style"], "color: red; margin: 0")
    end)

    it("applies no style at all when the prop is absent", function()
      local bridge = makeBridge()
      local host = domHostModule.createDomHost(bridge)
      local el = host.createInstance("div", { id = "x" })
      assert.equal(css_of(el), "")
      assert.falsy(el.attrs["style"])
    end)
  end)

  describe("update (commitUpdate) -- add, change and remove", function()
    it("ADDS a property that appeared in the new render", function()
      local bridge = makeBridge()
      local host = domHostModule.createDomHost(bridge)
      local old = { style = { color = "red" } }
      local el = host.createInstance("div", old)
      host.commitUpdate(el, old, { style = { color = "red", fontWeight = "bold" } })

      assert.equal(el.style_props["color"], "red")
      assert.equal(el.style_props["font-weight"], "bold")
    end)

    it("CHANGES a property whose value differs", function()
      local bridge = makeBridge()
      local host = domHostModule.createDomHost(bridge)
      local old = { style = { color = "red" } }
      local el = host.createInstance("div", old)
      host.commitUpdate(el, old, { style = { color = "green" } })

      assert.equal(el.style_props["color"], "green")
    end)

    it("REMOVES a property no longer present -- the whole point of diffing", function()
      local bridge = makeBridge()
      local host = domHostModule.createDomHost(bridge)
      local old = { style = { color = "red", backgroundColor = "blue" } }
      local el = host.createInstance("div", old)
      host.commitUpdate(el, old, { style = { color = "red" } })

      assert.equal(el.style_props["color"], "red")
      -- Left stale by any "re-apply the new table" implementation that
      -- does not diff against the previous one.
      assert.equal(el.style_props["background-color"], nil)
    end)

    it("does all three at once in a single update", function()
      local bridge = makeBridge()
      local host = domHostModule.createDomHost(bridge)
      local old = { style = { color = "red", backgroundColor = "blue", padding = 4 } }
      local el = host.createInstance("div", old)
      host.commitUpdate(el, old, { style = { color = "green", padding = 4, margin = 2 } })

      assert.equal(el.style_props["color"], "green")          -- changed
      assert.equal(el.style_props["background-color"], nil)   -- removed
      assert.equal(el.style_props["padding"], "4px")          -- unchanged
      assert.equal(el.style_props["margin"], "2px")           -- added
    end)

    it("does not touch unrelated properties another code path set", function()
      local bridge = makeBridge()
      local host = domHostModule.createDomHost(bridge)
      local old = { style = { color = "red" } }
      local el = host.createInstance("div", old)
      -- Something outside the reconciler (an animation, a third-party
      -- script) sets a property hydronium never knew about.
      el.style_props["transform"] = "translateX(10px)"
      host.commitUpdate(el, old, { style = { color = "green" } })

      assert.equal(el.style_props["transform"], "translateX(10px)")
      assert.equal(el.style_props["color"], "green")
    end)

    it("drops the whole inline style when the style prop disappears", function()
      local bridge = makeBridge()
      local host = domHostModule.createDomHost(bridge)
      local old = { style = { color = "red" } }
      local el = host.createInstance("div", old)
      host.commitUpdate(el, old, {})

      assert.equal(css_of(el), "")
      assert.falsy(el.attrs["style"])
    end)

    it("removes a property whose value became nil", function()
      local bridge = makeBridge()
      local host = domHostModule.createDomHost(bridge)
      local old = { style = { color = "red", margin = 4 } }
      local el = host.createInstance("div", old)
      host.commitUpdate(el, old, { style = { color = "red", margin = nil } })
      assert.equal(el.style_props["margin"], nil)
    end)

    it("removes a property whose value became false or empty", function()
      local bridge = makeBridge()
      local host = domHostModule.createDomHost(bridge)
      local old = { style = { color = "red", margin = 4, padding = 2 } }
      local el = host.createInstance("div", old)
      host.commitUpdate(el, old, { style = { color = "red", margin = false, padding = "" } })
      assert.equal(el.style_props["margin"], nil)
      assert.equal(el.style_props["padding"], nil)
    end)

    it("clears stale declarations when switching from a string to a table", function()
      local bridge = makeBridge()
      local host = domHostModule.createDomHost(bridge)
      local old = { style = "color: red; border: 1px solid" }
      local el = host.createInstance("div", old)
      host.commitUpdate(el, old, { style = { color = "green" } })

      assert.equal(el.style_props["color"], "green")
      assert.equal(el.style_props["border"], nil)
    end)

    it("replaces everything when switching from a table to a string", function()
      local bridge = makeBridge()
      local host = domHostModule.createDomHost(bridge)
      local old = { style = { color = "red", margin = 4 } }
      local el = host.createInstance("div", old)
      host.commitUpdate(el, old, { style = "padding: 0" })

      assert.equal(el.attrs["style"], "padding: 0")
      assert.equal(el.style_props["margin"], nil)
    end)
  end)

  describe("bridges without per-property style support", function()
    -- set_style_property/remove_style_property are OPTIONAL, so a bridge
    -- written before they existed must keep working.
    it("still produces the right style via the attribute fallback", function()
      local bridge = makeBridge({ per_property = false })
      local host = domHostModule.createDomHost(bridge)
      local old = { style = { color = "red", backgroundColor = "blue" } }
      local el = host.createInstance("div", old)
      assert.equal(el.attrs["style"], "background-color: blue; color: red")

      host.commitUpdate(el, old, { style = { color = "green" } })
      assert.equal(el.attrs["style"], "color: green")
      assert.equal(el.style_props["background-color"], nil)
    end)

    it("does not require the optional functions to construct a host", function()
      local bridge = makeBridge({ per_property = false })
      assert.truthy(domHostModule.createDomHost(bridge))
    end)
  end)

  describe("SSR and client agree (hydration safety)", function()
    -- The invariant: SSR emits `escape_html(style.serialize(s))` inside a
    -- quoted attribute; the client applies `style.serialize(s)` raw. So
    -- unescaping SSR's attribute must yield exactly the client's CSS.
    local function unescape(s)
      s = s:gsub("&quot;", '"'):gsub("&#39;", "'")
      s = s:gsub("&lt;", "<"):gsub("&gt;", ">")
      return (s:gsub("&amp;", "&"))
    end

    local shapes = {
      { name = "simple table", value = { color = "red" } },
      { name = "camelCase keys", value = { backgroundColor = "blue", marginTop = 8 } },
      { name = "kebab-case keys", value = { ["background-color"] = "blue", ["margin-top"] = 8 } },
      { name = "unitless numbers", value = { opacity = 0.8, zIndex = 10, lineHeight = 1.5 } },
      { name = "px numbers", value = { width = 200, height = 60 } },
      { name = "mixed", value = { color = "white", fontSize = 14, flexGrow = 1 } },
      { name = "dropped values", value = { color = "red", margin = false, padding = "" } },
      { name = "raw string", value = "display: flex; align-items: center" },
    }

    for _, shape in ipairs(shapes) do
      it("produces identical CSS on both sides: " .. shape.name, function()
        local bridge = makeBridge()
        local host = domHostModule.createDomHost(bridge)
        local el = host.createInstance("div", { style = shape.value })

        local client_css
        if type(shape.value) == "string" then
          client_css = el.attrs["style"]
        else
          client_css = css_of(el)
        end

        local ssr_attr = html.serialize_style(shape.value)
        assert.equal(unescape(ssr_attr), client_css)
      end)
    end

    it("escapes for SSR while the client applies raw CSS", function()
      -- A value containing a quote must be escaped in the attribute, but
      -- must NOT be escaped when handed to setProperty.
      local value = { fontFamily = '"Fira Code", monospace' }
      local ssr_attr = html.serialize_style(value)
      assert.truthy(ssr_attr:find("&quot;", 1, true))

      local raw = style_util.serialize(value)
      assert.falsy(raw:find("&quot;", 1, true))
      assert.equal(unescape(ssr_attr), raw)
    end)

    it("orders declarations deterministically", function()
      -- Lua's pairs() order is undefined; SSR output must not be.
      local a = style_util.serialize({ zIndex = 1, color = "red", background = "blue" })
      for _ = 1, 20 do
        assert.equal(style_util.serialize({ zIndex = 1, color = "red", background = "blue" }), a)
      end
      assert.equal(a, "background: blue; color: red; z-index: 1")
    end)

    it("keeps the SSR module's public helpers working after extraction", function()
      -- serialize_style/camel_to_kebab/UNITLESS_NUMBER_PROPS are still
      -- part of hydronium_dom.server.html's API; they now delegate.
      assert.equal(html.camel_to_kebab("backgroundColor"), "background-color")
      assert.equal(html.camel_to_kebab("background-color"), "background-color")
      assert.truthy(html.UNITLESS_NUMBER_PROPS["z-index"])
      assert.equal(html.serialize_style({ color = "red" }), "color: red")
    end)
  end)

  describe("hydrateProps", function()
    it("applies a table style onto a claimed SSR node", function()
      local bridge = makeBridge()
      local host = domHostModule.createDomHost(bridge)
      local el = bridge.create_element("div")
      host.hydrateProps(el, { style = { color = "red" } })
      assert.equal(el.style_props["color"], "red")
    end)
  end)
end)
