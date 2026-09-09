--[[
  Native tests for hydronium.host.dom -- the real browser DOM Host
  adapter. Before this file, `grep -rn "host.dom\|createDomHost" tests/`
  matched nothing but a doc-comment mention: this module's ONLY
  verification was a Playwright run against a real browser
  (examples/meteorite_ssr/hmr_demo/dom_host_proof.html), which is real
  and valuable but not part of `luajit tests/runner.lua`, not fast, and
  not something CI (or a quick local check) exercises.

  `hydronium.host.dom` is pure dispatch over a bridge table -- exactly
  the kind of thing that's cheap to test with a FAKE bridge instead of a
  real DOM, the same way `TestHost` stands in for a real DOM in every
  other reconciler-level test in this suite. `createDomHost(bridge)`
  accepting an explicit bridge table (rather than only reading `__dom_*`
  globals) exists specifically so this file doesn't have to mutate `_G`.
--]]

local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert

local domHostModule = require("hydronium_dom.host.dom")

--- A fake bridge: real in-memory nodes (plain tables), no real DOM, but
--- a REAL implementation of the documented contract -- not a mock that
--- just records calls. Lets these tests assert on actual resulting
--- state (attributes present, listeners attached, tree shape) rather
--- than "was this function called."
local function makeFakeBridge()
  local nextId = 0
  local function newNode(kind)
    nextId = nextId + 1
    return { id = nextId, kind = kind, attrs = {}, listeners = {}, children = {}, parent = nil, text = nil, tag = nil }
  end

  local function detach(node)
    if node.parent then
      local siblings = node.parent.children
      for i = 1, #siblings do
        if siblings[i] == node then table.remove(siblings, i); break end
      end
      node.parent = nil
    end
  end

  local calls = {}
  local function log(name, ...) table.insert(calls, { name, ... }) end

  local bridge = {}
  bridge.calls = calls

  function bridge.create_element(tag)
    log("create_element", tag)
    local n = newNode("element")
    n.tag = tag
    return n
  end

  function bridge.create_text(text)
    log("create_text", text)
    local n = newNode("text")
    n.text = text
    return n
  end

  function bridge.set_text(node, text)
    log("set_text", node.id, text)
    node.text = text
  end

  function bridge.append_child(parent, child)
    log("append_child", parent.id, child.id)
    detach(child)
    child.parent = parent
    table.insert(parent.children, child)
  end

  function bridge.insert_before(parent, child, before)
    log("insert_before", parent.id, child.id, before and before.id)
    detach(child)
    child.parent = parent
    local idx = #parent.children + 1
    for i = 1, #parent.children do
      if parent.children[i] == before then idx = i; break end
    end
    table.insert(parent.children, idx, child)
  end

  function bridge.remove_child(parent, child)
    log("remove_child", parent.id, child.id)
    detach(child)
  end

  function bridge.set_attr(node, key, value)
    log("set_attr", node.id, key, value)
    node.attrs[key] = value
  end

  function bridge.remove_attr(node, key)
    log("remove_attr", node.id, key)
    node.attrs[key] = nil
  end

  function bridge.set_listener(node, eventName, fn)
    log("set_listener", node.id, eventName)
    node.listeners[eventName] = fn
  end

  function bridge.remove_listener(node, eventName)
    log("remove_listener", node.id, eventName)
    node.listeners[eventName] = nil
  end

  function bridge.first_child(node)
    return node.children[1]
  end

  function bridge.next_sibling(node)
    if not node.parent then return nil end
    local siblings = node.parent.children
    for i = 1, #siblings do
      if siblings[i] == node then return siblings[i + 1] end
    end
    return nil
  end

  function bridge.is_element(node)
    return node ~= nil and node.kind == "element"
  end

  function bridge.is_text(node)
    return node ~= nil and node.kind == "text"
  end

  function bridge.tag_of(node)
    return node and node.tag or nil
  end

  bridge.mismatches = {}
  function bridge.hydration_mismatch(reason)
    table.insert(bridge.mismatches, reason)
  end

  function bridge.is_comment(node)
    return node ~= nil and node.kind == "comment"
  end

  -- Test-only helper (not part of the real bridge contract) for building
  -- real SSR-shaped island-marker comment nodes directly into a fake
  -- PRE-EXISTING tree (bypassing bridge.append_child/its call log
  -- entirely -- a real browser's own HTML parser creates these nodes
  -- before any bridge call ever happens, exactly like the element/text
  -- nodes a real hydrate test's "pre-existing tree" setup already builds
  -- directly), so a hydrate test can exercise Reconciler:hydrate's
  -- comment-marker-skipping (core/reconciler.lua) without a real browser DOM.
  function bridge.append_comment_for_test(parent, text)
    local n = newNode("comment")
    n.text = text
    n.parent = parent
    table.insert(parent.children, n)
    return n
  end

  return bridge, function(tag) local n = newNode("element"); n.tag = tag; return n end
end

describe("hydronium.host.dom -- bridge validation", function()
  it("errors with a named list of missing functions rather than a bare nil-call", function()
    local ok, err = pcall(function()
      domHostModule.createDomHost({ create_element = function() end })
    end)
    assert.falsy(ok)
    assert.truthy(tostring(err):find("create_text"), "must name a real missing function")
    assert.truthy(tostring(err):find("missing required DOM bridge function"))
  end)

  it("accepts a fully-populated explicit bridge table with no globals involved", function()
    local bridge = makeFakeBridge()
    local host = domHostModule.createDomHost(bridge)
    assert.truthy(host.createInstance)
    assert.truthy(host.hydrationMismatch)
  end)
end)

describe("hydronium.host.dom -- element/text creation and attributes", function()
  it("createInstance creates a real node and applies non-event props as attributes", function()
    local bridge = makeFakeBridge()
    local host = domHostModule.createDomHost(bridge)

    local node = host.createInstance("button", { id = "counter-a", class = "btn" })
    assert.equal(node.tag, "button")
    assert.equal(node.attrs.id, "counter-a")
    assert.equal(node.attrs.class, "btn")
  end)

  it("createInstance never forwards children/key/ref as attributes", function()
    local bridge = makeFakeBridge()
    local host = domHostModule.createDomHost(bridge)

    local node = host.createInstance("div", { children = {}, key = "k1", ref = {}, id = "x" })
    assert.equal(node.attrs.children, nil)
    assert.equal(node.attrs.key, nil)
    assert.equal(node.attrs.ref, nil)
    assert.equal(node.attrs.id, "x")
  end)

  it("createTextInstance creates a real text node", function()
    local bridge = makeFakeBridge()
    local host = domHostModule.createDomHost(bridge)
    local node = host.createTextInstance(42)
    assert.equal(node.kind, "text")
    assert.equal(node.text, "42")
  end)
end)

describe("hydronium.host.dom -- event props", function()
  it("an onXxx prop whose value is a function becomes a real listener, not an attribute", function()
    local bridge = makeFakeBridge()
    local host = domHostModule.createDomHost(bridge)
    local clicked = false
    local node = host.createInstance("button", { onClick = function() clicked = true end })

    assert.equal(node.attrs.onClick, nil, "must not be set as a literal attribute")
    assert.truthy(node.listeners.click, "must be registered under the lowercased event name")
    node.listeners.click()
    assert.truthy(clicked)
  end)

  it("onMouseEnter maps to the real DOM event name mouseenter", function()
    local bridge = makeFakeBridge()
    local host = domHostModule.createDomHost(bridge)
    local node = host.createInstance("div", { onMouseEnter = function() end })
    assert.truthy(node.listeners.mouseenter)
  end)

  it("commitUpdate REPLACES the listener -- old handler never also fires after an update", function()
    local bridge = makeFakeBridge()
    local host = domHostModule.createDomHost(bridge)
    local node = host.createInstance("button", {})

    local oldCalls, newCalls = 0, 0
    host.commitUpdate(node, {}, { onClick = function() oldCalls = oldCalls + 1 end })
    host.commitUpdate(node, { onClick = function() end }, { onClick = function() newCalls = newCalls + 1 end })

    node.listeners.click()
    assert.equal(oldCalls, 0, "the old closure must never run")
    assert.equal(newCalls, 1, "exactly the new closure runs, exactly once")
  end)

  it("commitUpdate removes a listener whose prop was dropped entirely", function()
    local bridge = makeFakeBridge()
    local host = domHostModule.createDomHost(bridge)
    local node = host.createInstance("button", { onClick = function() end })
    assert.truthy(node.listeners.click)

    host.commitUpdate(node, { onClick = function() end }, {})
    assert.equal(node.listeners.click, nil)
  end)

  it("a non-function value for an onXxx-shaped key removes any existing listener instead of setting a literal attribute", function()
    local bridge = makeFakeBridge()
    local host = domHostModule.createDomHost(bridge)
    local node = host.createInstance("button", { onClick = function() end })
    host.commitUpdate(node, { onClick = function() end }, { onClick = false })
    assert.equal(node.listeners.click, nil)
    assert.equal(node.attrs.onClick, nil)
  end)
end)

describe("hydronium.host.dom -- attribute diffing", function()
  it("commitUpdate adds, changes, and removes plain attributes correctly", function()
    local bridge = makeFakeBridge()
    local host = domHostModule.createDomHost(bridge)
    local node = host.createInstance("div", { id = "a", class = "old" })

    host.commitUpdate(node, { id = "a", class = "old" }, { id = "a", class = "new", title = "hi" })
    assert.equal(node.attrs.id, "a")
    assert.equal(node.attrs.class, "new")
    assert.equal(node.attrs.title, "hi")

    host.commitUpdate(node, { id = "a", class = "new", title = "hi" }, { id = "a" })
    assert.equal(node.attrs.class, nil)
    assert.equal(node.attrs.title, nil)
  end)

  it("a false or nil prop value removes the attribute rather than setting a literal 'false'", function()
    local bridge = makeFakeBridge()
    local host = domHostModule.createDomHost(bridge)
    local node = host.createInstance("input", { disabled = true })
    assert.equal(node.attrs.disabled, true)
    host.commitUpdate(node, { disabled = true }, { disabled = false })
    assert.equal(node.attrs.disabled, nil)
  end)

  it("commitTextUpdate updates a text node's content", function()
    local bridge = makeFakeBridge()
    local host = domHostModule.createDomHost(bridge)
    local node = host.createTextInstance("old")
    host.commitTextUpdate(node, "old", "new")
    assert.equal(node.text, "new")
  end)
end)

describe("hydronium.host.dom -- tree mutation", function()
  it("appendChild/insertBefore/removeChild maintain real parent/child structure", function()
    local bridge = makeFakeBridge()
    local host = domHostModule.createDomHost(bridge)
    local parent = host.createInstance("div", {})
    local a = host.createInstance("span", {})
    local b = host.createInstance("span", {})
    local c = host.createInstance("span", {})

    host.appendChild(parent, a)
    host.appendChild(parent, c)
    host.insertBefore(parent, b, c)

    assert.equal(#parent.children, 3)
    assert.equal(parent.children[1], a)
    assert.equal(parent.children[2], b)
    assert.equal(parent.children[3], c)

    host.removeChild(parent, b)
    assert.equal(#parent.children, 2)
    assert.equal(parent.children[1], a)
    assert.equal(parent.children[2], c)
  end)
end)

describe("hydronium.host.dom -- integration with the real Reconciler", function()
  it("mounts and updates a real small tree through Reconciler.mount/reconcile, not by calling host methods directly", function()
    local H = require("hydronium")
    local bridge = makeFakeBridge()
    local host = domHostModule.createDomHost(bridge)
    local reconciler = H.Reconciler.new(host)

    local vnode1 = H.h("div", { id = "root" },
      H.h("button", { onClick = function() end }, "Count: 0")
    )
    local rootNode = reconciler:mount(vnode1, nil, nil, nil)
    assert.equal(rootNode.tag, "div")
    assert.equal(rootNode.children[1].tag, "button")
    assert.equal(rootNode.children[1].children[1].text, "Count: 0")

    local vnode2 = H.h("div", { id = "root" },
      H.h("button", { onClick = function() end }, "Count: 1")
    )
    reconciler:reconcile(nil, vnode1, vnode2, nil)
    assert.equal(rootNode.children[1].children[1].text, "Count: 1", "the SAME text node must have been updated in place")
  end)

  it("hydrates through real HTML comment island markers (d.lua.mount's own SSR output shape) "
    .. "without falling back to a full remount -- regression test for a real bug found live via "
    .. "Playwright (see core/reconciler.lua's own doc comment on the FRAGMENT/transparent-island "
    .. "branch, and docs/HYDRONIUM_BALLAD_ARCHITECTURE_PLAN.md's M4 section)", function()
    local H = require("hydronium")
    local dom = require("hydronium_dom")
    local bridge, make_root = makeFakeBridge()
    local host = domHostModule.createDomHost(bridge)
    local reconciler = H.Reconciler.new(host)

    -- Build the exact real shape hydronium_dom.server emits for a
    -- root-mounted app: <!--hy:i:ID:lua--><button>...</button><!--hy:/i:ID-->
    local root = make_root("div")
    bridge.append_comment_for_test(root, "hy:i:hy:i1:lua")
    local realButton = make_root("button")
    realButton.parent = root
    table.insert(root.children, realButton)
    local realText = { id = "t1", kind = "text", text = "Count: 10", children = {}, attrs = {}, listeners = {} }
    realText.parent = realButton
    table.insert(realButton.children, realText)
    bridge.append_comment_for_test(root, "hy:/i:hy:i1")

    local function App(props)
      return dom.d.lua.mount(H.h("button", nil, "Count: " .. tostring(props.initial)))
    end
    local tree = H.h(App, { initial = 10 })

    local hostNode = reconciler:hydrateRoot(tree, root)

    assert.equal(hostNode, realButton, "must claim the real pre-existing button, not create a new one")
    assert.equal(#bridge.mismatches, 0, "must report zero hydration mismatches: " .. table.concat(bridge.mismatches, ", "))
    local created_new_element = false
    for _, call in ipairs(bridge.calls) do
      if call[1] == "create_element" then created_new_element = true end
    end
    assert.falsy(created_new_element, "must not create a new element when the real tree already matches")
    -- The comment markers themselves must still be there, untouched --
    -- skipping them for matching purposes is not the same as removing them.
    assert.equal(#root.children, 3, "the two comment markers plus the real button must all still be present")
  end)
end)
