local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert

local graph = require("hydronium.core.module_graph")
local family = require("hydronium.core.family")
local family_loader = require("hydronium.core.family_loader")
local hmr = require("hydronium.core.hmr")
local hmr_host = require("hydronium.core.hmr_host")

describe("runtime module graph observations", function()
  it("records nested require edges, reverse edges, and cache hits without changing results", function()
    local parent = "scratch.module_graph.parent"
    local child = "scratch.module_graph.child"
    graph.reset()
    package.loaded[parent] = nil
    package.loaded[child] = nil
    package.preload[parent] = function()
      local dep = require(child)
      return { value = dep.value + 1 }
    end
    package.preload[child] = function()
      return { value = 41 }
    end

    graph.manage(parent, { revision = "parent-r1", effects = "safe" })
    graph.enable()
    assert.equal(require(parent).value, 42)
    assert.equal(require(parent).value, 42, "the second require is an ordinary cache hit")

    local parent_node = graph.get(parent)
    local child_node = graph.get(child)
    assert.truthy(parent_node.dependencies[child])
    assert.truthy(child_node.importers[parent])
    assert.equal(parent_node.generation, 1)
    assert.equal(child_node.generation, 1)
    assert.equal(parent_node.revision, "parent-r1")
    assert.equal(parent_node.coverage, "managed")
    assert.equal(child_node.coverage, "observed")

    package.preload[parent] = nil
    package.preload[child] = nil
    package.loaded[parent] = nil
    package.loaded[child] = nil
    graph.reset()
  end)

  it("plans dependency-first hot updates and rejects a failed batch before refreshing families", function()
    local util, app = "scratch.module_graph.util", "scratch.module_graph.app"
    graph.reset(); family.reset(); family_loader.reset()
    package.loaded[util], package.loaded[app] = nil, nil
    hmr.install(util, "return { label = 'old' }")
    hmr.install(app, "local u = require('" .. util .. "'); return function() return u.label end")
    graph.manage(util, { effects = "safe" })
    graph.manage(app, { effects = "safe" })
    family_loader.enable()
    local App = require(app)
    -- lookup is normally reached by ComponentInstance; this is the smallest
    -- graph-only proof that the app export is a mounted-family boundary.
    family_loader.lookup(App)
    local plan = graph.plan({ util })
    assert.equal(plan.outcome, "hot")
    assert.equal(plan.modules[1], util)
    assert.equal(plan.modules[2], app)

    local rejected = hmr.apply_batch({ [util] = "error('bad replacement')" })
    assert.equal(rejected.outcome, "rejected")
    assert.equal(require(util).label, "old", "failed evaluation restores the old loaded module")

    local applied = hmr.apply_batch({
      [util] = "return { label = 'new' }",
      [app] = "local u = require('" .. util .. "'); return function() return 'app-' .. u.label end",
    }, {
      revision = "batch-r2",
      revisions = { [util] = "util-r2", [app] = "app-r2" },
    })
    assert.equal(applied.outcome, "hot")
    assert.equal(applied.revision, "batch-r2")
    assert.equal(require(app)(), "app-new", "the complete source batch must be visible after one commit")
    assert.equal(graph.get(util).revision, "util-r2")
    assert.equal(graph.get(app).revision, "app-r2")

    package.preload[util], package.preload[app] = nil, nil
    package.loaded[util], package.loaded[app] = nil, nil
    graph.reset(); family_loader.reset(); family.reset()
  end)

  it("returns explicit installed, remount, and restart outcomes", function()
    graph.reset()
    graph.manage("scratch.unloaded", { effects = "safe" })
    assert.equal(graph.plan({ "scratch.unloaded" }).outcome, "installed")
    package.loaded["scratch.unloaded"] = true
    assert.equal(graph.plan({ "scratch.unloaded" }, { root = "app-root" }).outcome, "remount")
    assert.equal(graph.plan({ "scratch.unloaded" }).outcome, "restart")
    package.loaded["scratch.unloaded"] = nil
    graph.reset()
  end)

  it("offers hosts a frame-safe queued batch boundary", function()
    local host = hmr_host.new()
    host:queue("scratch.queued", "return { value = 7 }", "module-r1", "safe")
    local result = host:flush("batch-r1")
    assert.equal(result.outcome, "installed")
    assert.equal(result.revision, "batch-r1")
    assert.equal(graph.get("scratch.queued").revision, "module-r1")
    assert.equal(require("scratch.queued").value, 7)
    assert.equal(host:flush(), nil)

    host:queue("scratch.queued", "return { value = 8 }", "module-r1", "safe")
    local duplicate = host:flush("batch-r1")
    assert.equal(duplicate.outcome, "skipped")
    assert.equal(require("scratch.queued").value, 7, "a replayed revision must not be applied twice")
    package.preload["scratch.queued"] = nil
    package.loaded["scratch.queued"] = nil
    graph.reset()
  end)

  it("fails closed when any affected importer lacks an effect-safety declaration", function()
    local util, app = "scratch.effect_boundary.util", "scratch.effect_boundary.app"
    graph.reset(); family_loader.reset()
    package.loaded[util], package.loaded[app] = nil, nil
    hmr.install(util, "return { value = 1 }")
    hmr.install(app, "local u = require('" .. util .. "'); return function() return u.value end")
    graph.manage(util, { effects = "safe" })
    family_loader.enable()
    require(app)

    local plan = graph.plan({ util })
    assert.equal(plan.outcome, "restart")
    assert.equal(plan.reason, "effect_boundary:" .. app)

    package.preload[util], package.preload[app] = nil, nil
    package.loaded[util], package.loaded[app] = nil, nil
    graph.reset(); family_loader.reset()
  end)
end)
