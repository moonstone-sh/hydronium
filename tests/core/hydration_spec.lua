--[[
  General Reconciler hydration -- Reconciler:hydrate()/hydrateRoot().

  Proves the counter-agent audit's Part IV requirement natively before
  the slow real-browser proof: hydration must walk the host's OWN
  existing tree structurally (element/text kind + tag matching), not a
  Counter-specific comment-marker/button bridge like
  hydronium.interpreter.lua's `hy_find_island`/`hy_query_button`. Uses
  TestHost, exercising the exact same Reconciler:hydrate() code path the
  real DOM host (src/hydronium/host/dom.lua) also drives -- only the
  host implementation differs, per the Host contract's own design.
--]]

local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert

local H = require("hydronium")

local function findOp(log, op)
  for i = 1, #log do
    if log[i].op == op then return log[i] end
  end
  return nil
end

describe("General Reconciler hydration (Reconciler:hydrate/hydrateRoot)", function()
  it("claims a real pre-existing tree with zero new nodes created", function()
    local host = H.test.createTestHost()
    local root = host.getRoot()

    -- Build the "already-rendered" tree by hand, standing in for real
    -- SSR output the browser already parsed -- exactly what hydration
    -- must claim, not rebuild.
    local divNode = host.createInstance("div", {})
    local h1Node = host.createInstance("h1", {})
    local h1Text = host.createTextInstance("Header")
    host.appendChild(h1Node, h1Text)
    local buttonNode = host.createInstance("button", {})
    local buttonText = host.createTextInstance("Count: 10")
    host.appendChild(buttonNode, buttonText)
    host.appendChild(divNode, h1Node)
    host.appendChild(divNode, buttonNode)
    host.appendChild(root, divNode)

    host.clear_log()

    local vnode = H.h("div", nil,
      H.h("h1", nil, "Header"),
      H.h("button", { onClick = function() end }, "Count: 10")
    )

    local reconciler = H.Reconciler.new(host)
    local resultHostNode = reconciler:hydrateRoot(vnode, root)

    assert.equal(resultHostNode, divNode, "hydrateRoot must return the claimed root node, not a new one")
    assert.equal(vnode.hostNode, divNode)
    assert.equal(vnode.children[1].hostNode, h1Node, "the <h1> vnode must claim the real <h1> node")
    assert.equal(vnode.children[1].children[1].hostNode, h1Text, "the header text vnode must claim the real text node")
    assert.equal(vnode.children[2].hostNode, buttonNode, "the <button> vnode must claim the real <button> node")
    assert.equal(vnode.children[2].children[1].hostNode, buttonText)

    local log = host.get_log()
    assert.falsy(findOp(log, "create_node"), "hydration must not create any new element -- the whole tree matched")
    assert.falsy(findOp(log, "create_text_node"), "hydration must not create any new text node -- the whole tree matched")
    assert.falsy(findOp(log, "hydration_mismatch"), "a fully-matching tree must report zero mismatches")
  end)

  it("falls back to mounting fresh through the SAME host contract on a real mismatch, and removes the wrong node", function()
    local host = H.test.createTestHost()
    local root = host.getRoot()

    -- Server rendered a <div> where the client-side vnode tree expects
    -- a <button> -- a genuine, not simulated, hydration mismatch.
    local wrongNode = host.createInstance("div", {})
    host.appendChild(root, wrongNode)

    host.clear_log()

    local vnode = H.h("button", nil, "Click")
    local reconciler = H.Reconciler.new(host)
    local resultHostNode = reconciler:hydrateRoot(vnode, root)

    assert.truthy(resultHostNode, "a mismatch must still produce a usable host node via fallback mount")
    assert.truthy(resultHostNode ~= wrongNode, "the fallback-mounted node must be a NEW node, not the mismatched one")
    assert.equal(resultHostNode.tag, "button")

    local log = host.get_log()
    assert.truthy(findOp(log, "hydration_mismatch"), "a real mismatch must be reported, not silently papered over")
    assert.truthy(findOp(log, "create_node"), "the mismatched vnode must be mounted through the ordinary host.createInstance path")
    assert.truthy(findOp(log, "remove_child"), "the wrong pre-existing node must be removed, not left as an orphaned live node")

    local children = root.children
    assert.equal(#children, 1, "exactly the new button must remain under root")
    assert.equal(children[1], resultHostNode)
  end)

  it("reports and removes leftover real children the vnode tree never accounted for", function()
    local host = H.test.createTestHost()
    local root = host.getRoot()

    local divNode = host.createInstance("div", {})
    local extraSpan = host.createInstance("span", {})
    host.appendChild(divNode, extraSpan)
    host.appendChild(root, divNode)

    host.clear_log()

    -- vnode tree claims the <div> but declares no children at all --
    -- the real <span> inside it is a genuine leftover.
    local vnode = H.h("div", nil)
    local reconciler = H.Reconciler.new(host)
    reconciler:hydrateRoot(vnode, root)

    local log = host.get_log()
    assert.truthy(findOp(log, "hydration_mismatch"), "an unaccounted-for real child must be reported as a mismatch")
    assert.equal(#divNode.children, 0, "the leftover child must actually be removed, not just logged")
  end)
end)
