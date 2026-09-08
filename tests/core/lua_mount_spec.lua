--[[
  `d.lua.mount(<App/>)` client-path correctness (H5 in the client-SPA
  audit's gap list).

  Before this fix, `hydronium/dom/init.lua`'s own doc comment claimed
  `d.lua.mount(vnode)` was "the semantic equivalent of `<d.lua.island
  root>`, so a full Lua-hydrated application and a partial Lua island
  share the exact same client machinery." This was false: `d.lua.mount`
  produces an ISLAND-kind VNode, and `Reconciler:mount`/`:hydrate` both
  unconditionally `error()`ed on every ISLAND ("has no client
  reconciler yet"). The one artifact that proved the DOM host worked
  (examples/meteorite_ssr/hmr_demo/dom_host_proof.html) had to bypass
  `d.lua.mount` entirely and hand-build a plain element tree instead --
  confirmed by a later audit, which is why this fix and this test exist.

  `Reconciler` now treats an ISLAND vnode whose descriptor has
  `interpreter == "lua"` transparently, like a Fragment, for mount,
  hydrate, reconcile, and unmount -- there is no cross-language boundary
  left to cross once you're already inside the Lua VM that's running
  the reconciler itself (unlike a "js" island, which stays a real "no
  client reconciler yet" case -- js-island hydration is a different
  code path entirely, bootstrap.js's dynamic import, never this
  reconciler).
--]]

local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert

local H = require("hydronium")
local dom = require("hydronium_dom")

describe("d.lua.mount client-path correctness", function()
  it("mounts through the ordinary Reconciler instead of erroring", function()
    local host = H.test.createTestHost()
    local reconciler = H.Reconciler.new(host)

    local function App(props)
      return H.h("div", { id = "app" }, "Hello, " .. props.name)
    end

    local tree = dom.lua.mount(H.h(App, { name = "World" }))
    local hostNode = reconciler:mount(tree, host.getRoot(), nil, nil)

    assert.truthy(hostNode, "mount must succeed, not error")
    assert.equal(hostNode.tag, "div")
    assert.equal(hostNode.children[1].text, "Hello, World")
  end)

  it("hydrates a real pre-existing tree through Reconciler:hydrateRoot, exactly like an ordinary root", function()
    local host = H.test.createTestHost()
    local root = host.getRoot()

    local divNode = host.createInstance("div", { id = "app" })
    local textNode = host.createTextInstance("Hello, World")
    host.appendChild(divNode, textNode)
    host.appendChild(root, divNode)
    host.clear_log()

    local reconciler = H.Reconciler.new(host)
    local function App(props)
      return H.h("div", { id = "app" }, "Hello, " .. props.name)
    end
    local tree = dom.lua.mount(H.h(App, { name = "World" }))

    local hostNode = reconciler:hydrateRoot(tree, root)
    assert.equal(hostNode, divNode, "must claim the real pre-existing div, not create a new one")

    local log = host.get_log()
    for i = 1, #log do
      assert.truthy(log[i].op ~= "create_node", "hydration must not create a new element for a fully-matching tree")
    end
  end)

  it("reconciles an update through the ordinary path -- state changes reach the real DOM", function()
    local host = H.test.createTestHost()
    local reconciler = H.Reconciler.new(host)

    local function Counter(props, scope)
      local count, setCount = scope.refresh_registry:signal(props.initial or 0, {
        kind = "signal", name = "count", block_path = "Counter.setup",
      })
      return function()
        return H.h("button", { onClick = function() setCount(count() + 1) end }, "Count: " .. tostring(count()))
      end
    end

    local tree = dom.lua.mount(H.h(Counter, { initial = 0 }))
    reconciler:mount(tree, host.getRoot(), nil, nil)

    local buttonVNode = reconciler:getHostNode(tree)
    assert.equal(buttonVNode.children[1].text, "Count: 0")

    -- Drive the real onClick that mounting actually wired up. `tree`
    -- itself is the ISLAND wrapper vnode; the Counter component vnode
    -- is its child.
    tree.children[1].componentInstance.subTree.props.onClick()
    assert.equal(reconciler:getHostNode(tree).children[1].text, "Count: 1")
  end)

  it("unmounts cleanly, disposing the wrapped component like any ordinary root", function()
    local host = H.test.createTestHost()
    local reconciler = H.Reconciler.new(host)

    local disposed = false
    local function App(props, scope)
      H.onCleanup(function() disposed = true end)
      return function() return H.h("div", nil, "x") end
    end

    local tree = dom.lua.mount(H.h(App, {}))
    reconciler:mount(tree, host.getRoot(), nil, nil)
    reconciler:unmount(tree)

    assert.truthy(disposed, "unmounting a lua-mounted root must dispose its component scope")
  end)

  it("a JS island (interpreter == 'js') is UNCHANGED -- still errors, since real js-island hydration is a different code path entirely", function()
    local host = H.test.createTestHost()
    local reconciler = H.Reconciler.new(host)
    local jsIslandVNode = H.h(dom.d.js.island, { module = "/x.js" }, H.h("div", nil, "x"))

    local ok, err = pcall(function()
      reconciler:mount(jsIslandVNode, host.getRoot(), nil, nil)
    end)
    assert.falsy(ok, "a js island must still be refused by this reconciler, unchanged")
    assert.truthy(tostring(err):find("no client reconciler yet"))
  end)
end)
