-- Tests for hydronium_dom.server.render_page -- the page scope that makes
-- island ids and the client plan page-global rather than per-render-call.
--
-- The bug this exists to prevent was found by a real browser run
-- (js/examples/islands-tailwind/tests/dual-hmr.test.mjs): a page composed of
-- two render_to_string calls minted `hy:i1` twice, and bootstrap.js -- which
-- resolves an island id against the whole document -- hydrated the second
-- island into the FIRST one's DOM node. It was silent apart from a
-- hydration-mismatch warning. See docs/HYDRONIUM_WEB_VITE_ADAPTER_PLAN.md.

local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert
local server = require("hydronium_dom.server")
local H = require("hydronium")
local dom = require("hydronium_dom")
local d = dom.d

local function js_island(id, initial)
  return H.h(d.js.island,
    { module = "./" .. id .. ".js", hydrate = "load", props = { initial = initial } },
    H.h("div", { id = id }, "island " .. id))
end

describe("hydronium_dom.server.render_page", function()
  it("keeps island ids unique across separate renders in one page", function()
    local html, plan = server.render_page(function(render)
      return render(js_island("a", 1)) .. render(js_island("b", 2))
    end)

    assert.equal(#plan.islands, 2)
    assert.not_equal(plan.islands[1].id, plan.islands[2].id)
    assert.equal(plan.islands[1].id, "hy:i1")
    assert.equal(plan.islands[2].id, "hy:i2")
    -- Both ids must appear in the composed markup, or the client cannot
    -- resolve them independently.
    assert.truthy(html:find("hy:i1", 1, true))
    assert.truthy(html:find("hy:i2", 1, true))
  end)

  it("merges every island into ONE client plan emitted once", function()
    local _, plan, plan_script = server.render_page(function(render)
      return render(js_island("a", 1)) .. render(js_island("b", 2))
    end)

    assert.equal(plan.version, "hydronium.client-plan.v1")
    assert.equal(#plan.islands, 2)
    -- Exactly one plan tag for the page, carrying both islands.
    local first = plan_script:find("__HYDRONIUM_CLIENT_PLAN__", 1, true)
    assert.truthy(first)
    assert.is_nil(plan_script:find("__HYDRONIUM_CLIENT_PLAN__", first + 1, true))
    assert.truthy(plan_script:find("hy:i1", 1, true))
    assert.truthy(plan_script:find("hy:i2", 1, true))
  end)

  it("does not emit a per-render plan tag inside the page", function()
    local html = server.render_page(function(render)
      return render(js_island("a", 1)) .. render(js_island("b", 2))
    end)
    assert.is_nil(html:find("__HYDRONIUM_CLIENT_PLAN__", 1, true))
  end)

  it("emits no plan script for a page that declares no client surface", function()
    local html, plan, plan_script = server.render_page(function(render)
      return render(H.h("p", nil, "purely static"))
    end)
    assert.equal(plan_script, "")
    assert.equal(#plan.islands, 0)
    assert.truthy(html:find("purely static", 1, true))
  end)

  it("leaves a bare render_to_string resetting per call, as before", function()
    local _, plan_a = server.render_to_string(js_island("a", 1))
    local _, plan_b = server.render_to_string(js_island("b", 2))
    -- Backwards compatibility: outside a page, each call owns its own
    -- sequence and plan -- ids restart, exactly as they always did.
    assert.equal(plan_a.islands[1].id, "hy:i1")
    assert.equal(plan_b.islands[1].id, "hy:i1")
  end)

  it("refuses to nest", function()
    assert.has_error(function()
      server.render_page(function(render)
        return server.render_page(function() return "" end)
      end)
    end, "not reentrant")
  end)

  it("releases the page scope when the callback errors", function()
    assert.has_error(function()
      server.render_page(function() error("boom", 0) end)
    end, "boom")
    -- A later page must still start from a clean sequence; if the scope
    -- leaked, ids would keep counting from the failed page.
    local _, plan = server.render_page(function(render)
      return render(js_island("a", 1))
    end)
    assert.equal(plan.islands[1].id, "hy:i1")
  end)
end)
