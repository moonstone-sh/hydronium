local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert
local hydronium = require("hydronium")
local ink = require("hydronium_ink")
local hooks = require("hydronium_ink.hooks")
local lab = require("hydronium_lab")
local inkLab = require("hydronium_ink_lab")
local server = require("hydronium_dom.server")

describe("hydronium Ink Lab", function()
  it("discovers and binds .stories.lua and .stories.luax deterministically", function()
    local discovery = lab.discovery
    local records = discovery.plan({
      "README.md",
      "src/widgets/Status.stories.luax",
      "src/Button.stories.lua",
    })
    assert.equal(records[1].path, "src/Button.stories.lua")
    assert.equal(records[1].id_prefix, "button")
    assert.equal(records[2].transform, "luax")
    assert.equal(records[2].id_prefix, "widgets/status")

    local registry = discovery.registry(records, function(record)
      if record.id_prefix == "button" then
        return lab.collection({
          title = "Components/Button",
          component = function(props) return hydronium.h(ink.Text, nil, props.label) end,
          controls = { label = { type = "text" } },
          stories = { default = { args = { label = "Press" } } },
        })
      end
      return lab.collection({
        title = "Widgets/Status",
        render = function(args) return hydronium.h(ink.Text, nil, args.state) end,
        stories = { healthy = { args = { state = "ok" } } },
      })
    end)
    assert.truthy(registry.get("button--default"))
    assert.equal(registry.get("widgets/status--healthy").group, "Widgets/Status")
    assert.equal(registry.manifest()[1].controls.label.type, "text")
  end)

  it("rejects ambiguous story stems, ids, and non-JSON controls", function()
    assert.has_error(function()
      lab.discovery.plan({ "src/Status.stories.lua", "src/Status.stories.luax" })
    end, "story stem collision")
    assert.has_error(function()
      lab.collection({ component = function() end, stories = { Default = {} } })
    end, "portable lowercase slugs")
    assert.has_error(function()
      lab.collection({
        component = function() end,
        controls = { value = { type = "select", options = {} } },
        stories = { default = {} },
      })
    end, "non-empty options")
  end)

  it("validates and composes explicit story registries", function()
    local story = lab.story({ id = "status/ok", render = function() return hydronium.h(ink.Text, nil, "ok") end })
    local registry = lab.registry({ lab.registry({ story }) })
    assert.equal(registry.get("status/ok"), story)
    assert.equal(registry.manifest()[1].sizes[1].columns, 80)
    assert.has_error(function() lab.registry({ story, story }) end, "duplicate story id")
  end)

  it("renders its browser shell through Hydronium DOM", function()
    local vnode = hydronium.h(inkLab.dom, {
      project_name = "Demo Lab",
      boot = lab.host.contract({ base_path = "/tools/components", renderer_stylesheet_asset = "assets/ink.css" }),
    })
    local html = server.renderToString(vnode)
    assert.truthy(html:find("data%-hydronium%-ink%-lab"))
    assert.truthy(html:find("data%-lab%-terminal"))
    assert.truthy(html:find("data%-lab%-grid"))
    assert.truthy(html:find("Demo Lab", 1, true))
    assert.truthy(html:find('data%-lab%-base%-path="/tools/components"'))
    assert.truthy(html:find('data%-lab%-catalog%-url="/tools/components/catalog"'))
    assert.truthy(html:find('data%-lab%-session%-operations%-url="/tools/components/sessions/{id}/operations"'))
    assert.truthy(html:find('href="/tools/components/assets/workbench.css"', 1, true))
    assert.truthy(html:find('href="/tools/components/assets/ink.css"', 1, true))
    assert.truthy(html:find('src="/tools/components/assets/meteorite.js"', 1, true))
  end)

  it("serves canonical styled frames and interactions through the transport-neutral protocol", function()
    local setValue
    local function Demo()
      local value
      value, setValue = hydronium.signal("idle")
      hooks.useInput(function(input) if input ~= "" then setValue(input) end end)
      return function()
        return hydronium.h(ink.Text, { color = "#ff0000", bold = true }, value())
      end
    end
    local registry = lab.registry({ lab.story({
      id = "demo/basic",
      render = function() return hydronium.h(Demo) end,
      sizes = { { name = "small", columns = 20, rows = 5 } },
      interactions = { { name = "complete", run = function() setValue("done") end } },
    }) })
    local runtime = inkLab.new(registry)
    local frame = runtime:request({ op = "open", story = "demo/basic" })
    assert.equal(frame.version, 1)
    assert.equal(frame.width, 20)
    assert.equal(frame.rows[1][1].ch, "i")
    assert.same(frame.rows[1][1].fg, { kind = "rgb", r = 255, g = 0, b = 0 })
    assert.truthy(frame.rows[1][1].bold)

    frame = runtime:request({ op = "input", input = "x", key = {} })
    assert.equal(frame.rows[1][1].ch, "x")
    frame = runtime:request({ op = "interaction", name = "complete", nowMs = 10 })
    assert.equal(frame.rows[1][1].ch, "d")
    frame = runtime:request({ op = "resize", columns = 12, rows = 3 })
    assert.equal(frame.width, 12)
    assert.equal(frame.height, 3)
    frame = runtime:request({ op = "open", story = "demo/basic", color = "ansi16" })
    assert.equal(frame.color, "ansi16")
    assert.same(frame.rows[1][1].fg, { kind = "palette", index = 1 })
    runtime:close()
  end)

  it("isolates, sequences, expires, and invalidates single-owner Lab sessions", function()
    local now, next_id = 10, 0
    local registry = lab.registry({ lab.story({
      id = "demo/session",
      render = function() return hydronium.h(ink.Text, nil, "session") end,
    }) })
    local service = inkLab.service.new(registry, {
      max_sessions = 2,
      idle_seconds = 5,
      clock = function() return now end,
      id = function() next_id = next_id + 1; return string.rep(tostring(next_id), 32) end,
    })
    local first, second = service:create(), service:create()
    assert.truthy(first.ok)
    assert.truthy(second.ok)
    assert.equal(service:create().outcome, "rate_limited")
    local opened = service:operate(first.session, {
      generation = "1", sequence = 1, request = { op = "open", story = "demo/session" },
    })
    assert.truthy(opened.ok)
    assert.equal(opened.result.rows[1][1].ch, "s")
    assert.equal(service:operate(first.session, {
      sequence = 1, request = { op = "snapshot" },
    }).outcome, "stale_sequence")
    now = 16
    assert.equal(service:sweep(), 2)
    assert.equal(service:operate(first.session, { sequence = 2, request = { op = "snapshot" } }).outcome, "session_expired")
    local third = service:create()
    service:invalidate("2")
    assert.equal(service:operate(third.session, { sequence = 1, request = { op = "snapshot" } }).outcome, "session_expired")
  end)
end)
