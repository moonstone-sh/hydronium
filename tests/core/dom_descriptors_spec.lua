local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert
local Hydronium = require("hydronium")
local symbols = require("hydronium.core.symbols")
local dom = require("hydronium.dom")
local d = dom.d

describe("Hydronium DOM Runtime Descriptors & Normalization", function()
  it("exports symbols.INTRINSIC", function()
    assert.truthy(symbols.INTRINSIC)
    assert.equal(symbols.INTRINSIC.name, "INTRINSIC")
    assert.truthy(symbols.isSymbol(symbols.INTRINSIC))
  end)

  it("exports immutable descriptor table d with standard tags", function()
    assert.is_table(d)
    assert.truthy(d.button)
    assert.equal(d.button["$$typeof"], symbols.INTRINSIC)
    assert.equal(d.button.tag, "button")
    assert.equal(d.button.host, "dom")

    assert.truthy(d.input)
    assert.equal(d.input.tag, "input")

    assert.truthy(d.div)
    assert.equal(d.div.tag, "div")

    assert.truthy(d.svg)
    assert.equal(d.svg.tag, "svg")
  end)

  it("enforces immutability on descriptor table d", function()
    local ok, err = pcall(function()
      d.customTag = 123
    end)
    assert.falsy(ok, "Expected modification of table d to fail")
  end)

  it("creates callable intrinsic descriptors that return VNodes with unwrapped tag", function()
    local node = d.button({ id = "submit-btn", disabled = true }, "Click me")
    assert.is_table(node)
    assert.equal(node._typeof, symbols.VNODE)
    assert.equal(node.kind, symbols.ELEMENT)
    assert.equal(node.tag, "button")
    assert.equal(node.props.id, "submit-btn")
    assert.equal(node.props.disabled, true)
  end)

  it("unwraps d.button when passed directly to createElement", function()
    local node = Hydronium.createElement(d.button, { className = "btn" }, "Submit")
    assert.equal(node.tag, "button")
    assert.equal(node.kind, symbols.ELEMENT)
  end)

  it("renders descriptor elements to HTML string in SSR", function()
    local node = d.button({ id = "my-btn", className = "primary" }, "Hello World")
    local html = Hydronium.renderToString(node)
    assert.equal(html, '<button class="primary" id="my-btn">Hello World</button>')
  end)

  it("renders void elements using descriptors without self-closing slash in SSR", function()
    local node = d.input({ type = "text", placeholder = "Enter name", disabled = true })
    local html = Hydronium.renderToString(node)
    assert.truthy(html:find("^<input"))
    assert.truthy(html:find('placeholder="Enter name"'))
    assert.truthy(html:find("disabled"))
  end)

  it("reconciler correctly handles and mounts elements created with d descriptors", function()
    local host = Hydronium.TestHost()
    local reconciler = Hydronium.Reconciler.new(host)

    local vnode1 = d.div({ id = "c1" }, d.button({ id = "b1" }, "Press"))
    local root = host.createInstance("root", {})
    reconciler:mount(vnode1, root)

    assert.equal(#root.children, 1)
    assert.equal(root.children[1].tag, "div")
    assert.equal(#root.children[1].children, 1)
    assert.equal(root.children[1].children[1].tag, "button")

    -- Test canReuse
    local vnode2 = d.div({ id = "c1" }, d.button({ id = "b1" }, "Updated Press"))
    assert.truthy(reconciler:canReuse(vnode1, vnode2))

    -- Reconcile
    reconciler:reconcile(root, vnode1, vnode2)
    assert.equal(#root.children, 1)
  end)
end)
