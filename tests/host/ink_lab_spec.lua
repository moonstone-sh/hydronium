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

    -- Deltas address changed cells as `{y, x, styleId, {ch, ...}}` row runs
    -- with 0-based y/x (see hydronium_ink_lab.frame); resolve the character
    -- at (x, y) the same way the browser client does.
    local function delta_char_at(frame, x, y)
      for _, change in ipairs(frame.changes or {}) do
        if change[1] == y and x >= change[2] and x < change[2] + #change[4] then
          return change[4][x - change[2] + 1]
        end
      end
    end

    local frame = runtime:request({ op = "open", story = "demo/basic" })
    assert.equal(frame.version, 2)
    assert.equal(frame.kind, "full")
    assert.equal(frame.width, 20)
    local first_run = frame.rows[1][1]
    assert.equal(first_run[2][1], "i")
    local first_style = frame.styles[tostring(first_run[1])]
    assert.same(first_style.fg, { kind = "rgb", r = 255, g = 0, b = 0 })
    assert.truthy(first_style.bold)

    frame = runtime:request({ op = "input", input = "x", key = {} })
    assert.equal(frame.kind, "delta")
    assert.equal(delta_char_at(frame, 0, 0), "x")
    frame = runtime:request({ op = "interaction", name = "complete", nowMs = 10 })
    assert.equal(delta_char_at(frame, 0, 0), "d")
    frame = runtime:request({ op = "resize", columns = 12, rows = 3 })
    assert.equal(frame.kind, "full")
    assert.equal(frame.width, 12)
    assert.equal(frame.height, 3)
    frame = runtime:request({ op = "open", story = "demo/basic", color = "ansi16" })
    assert.equal(frame.kind, "full")
    assert.equal(frame.color, "ansi16")
    local reopened_style = frame.styles[tostring(frame.rows[1][1][1])]
    assert.same(reopened_style.fg, { kind = "palette", index = 1 })
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
    assert.equal(opened.result.kind, "full")
    assert.equal(opened.result.rows[1][1][2][1], "s")
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

describe("Lab live state and playback", function()
  it("updates args without remounting and exposes reactive story hooks", function()
    local mounts, getArgs, setArgs, getCount = 0
    local function Preview()
      mounts = mounts + 1
      getArgs, setArgs = lab.useStoryArgs()
      local setCount
      getCount, setCount = hydronium.signal(0)
      hooks.useInput(function() setCount(getCount() + 1) end)
      return function() return hydronium.h(ink.Text, nil, getArgs().label .. getCount()) end
    end
    local registry = lab.registry({ lab.story({ id = "live", args = { label = "A" }, controls = { label = { type = "text" } },
      render = function() return hydronium.h(Preview) end }) })
    local runtime = inkLab.new(registry)
    runtime:request({ op = "open", story = "live" })
    runtime:request({ op = "input", input = "x" })
    local frame = runtime:request({ op = "args", args = { label = "B" } })
    assert.equal(frame.lab.args.label, "B")
    assert.equal(getArgs().label, "B")
    assert.equal(getCount(), 1)
    assert.equal(mounts, 1)
    setArgs({ label = "C" })
    assert.equal(runtime:request({ op = "snapshot" }).lab.args.label, "C")
    runtime:request({ op = "resetArgs" })
    assert.equal(getArgs().label, "A")
    runtime:close()
  end)

  it("primes animation time, freezes paused frames and advances explicitly", function()
    local animation, playback
    local function Preview()
      animation = hooks.useAnimation({ interval = 10 })
      playback = lab.usePlayback()
      return function() return hydronium.h(ink.Text, nil, tostring(animation.frame())) end
    end
    local runtime = inkLab.new(lab.registry({ lab.story({ id = "clock", render = function() return hydronium.h(Preview) end }) }))
    runtime:request({ op = "open", story = "clock" })
    assert.equal(animation.frame(), 0)
    runtime:request({ op = "step", nowMs = 20 })
    assert.equal(animation.frame(), 1)
    runtime:request({ op = "playback", playing = false, intervalMs = 10 })
    local frozen = runtime:request({ op = "step", nowMs = 9999 })
    assert.equal(frozen.lab.playback.nowMs, 20)
    assert.equal(animation.frame(), 1)
    local frame = runtime:request({ op = "advance" })
    assert.equal(frame.lab.playback.nowMs, 30)
    assert.equal(playback().playing, false)
    assert.equal(animation.frame(), 2)
    frame = runtime:request({ op = "seek", nowMs = 50 })
    assert.equal(frame.lab.playback.nowMs, 50)
    assert.has_error(function() runtime:request({ op = "seek", nowMs = 10 }) end, "restart")
    frame = runtime:request({ op = "restart" })
    assert.equal(frame.kind, "full")
    assert.equal(frame.lab.playback.nowMs, 0)
    assert.equal(frame.lab.playback.playing, false)
    assert.equal(animation.frame(), 0)
    assert.equal(frame.lab.playback.intervalMs, 10)
    runtime:close()
  end)

  it("validates edits before changing the live story and isolates sessions", function()
    local story = lab.story({ id = "validated", args = { value = 1, choice = false }, controls = {
      value = { type = "number", min = 0, max = 2 }, choice = { type = "select", options = { { label = "No", value = false }, { label = "Yes", value = true } } },
    }, render = function(args) return hydronium.h(ink.Text, nil, tostring(args.value)) end })
    local registry = lab.registry({ story })
    local a, b = inkLab.new(registry), inkLab.new(registry)
    a:request({ op = "open", story = story.id }); b:request({ op = "open", story = story.id })
    assert.has_error(function() a:request({ op = "args", args = { value = 9 } }) end, "outside its range")
    assert.has_error(function() a:request({ op = "args", args = { value = math.huge } }) end, "finite")
    assert.has_error(function() a:request({ op = "playback", intervalMs = 0 }) end, "positive")
    a:request({ op = "args", args = { value = 2, choice = true } })
    assert.equal(a.state.args().value, 2)
    assert.equal(b.state.args().value, 1)
    assert.has_error(function() a:request({ op = "open", story = story.id, args = { value = 9 } }) end, "outside its range")
    assert.equal(a:request({ op = "snapshot" }).lab.args.value, 2)
    a:close(); b:close()
  end)

  it("exposes source-accessible components and custom named control outlets", function()
    local components = require("hydronium_ink_lab.components")
    local ui = require("hydronium_lab.controls")
    assert.equal(components.Document, inkLab.dom)
    local html = server.renderToString(hydronium.h(components.Document, {
      controls = hydronium.h(ui.Controls, nil, hydronium.h(ui.Control, { name = "label", type = "text" })),
    }))
    assert.truthy(html:find('data-lab-control="label"', 1, true))
    assert.truthy(html:find('data-lab-timeline', 1, true))
    assert.truthy(html:find('data-lab-step', 1, true))
  end)
end)

describe("Lab story-specific DOM controls", function()
  it("preserves collection and variant outlets through discovery and the DOM shell", function()
    local function Controls() return hydronium.h("input", { ["data-lab-control"] = "label" }) end
    local function Variant() return hydronium.h("input", { ["data-lab-control"] = "count" }) end
    local registry = lab.discovery.registry(lab.discovery.plan({ "src/Label.stories.luax" }), function()
      return lab.collection({ component = function() end, controls_view = Controls,
        stories = { default = {}, variant = { controls_view = Variant } } })
    end)
    assert.equal(registry.get("label--default").controls_view, Controls)
    assert.equal(registry.get("label--variant").controls_view, Variant)
    local ui = require("hydronium_lab.controls")
    local html = server.renderToString(hydronium.h(inkLab.dom, { story_controls = {
      hydronium.h(ui.Controls, { story_id = "label--default" }, hydronium.h(Controls)),
    } }))
    assert.truthy(html:find('data-lab-controls-story="label--default"', 1, true))
    assert.truthy(html:find('data-lab-control="label"', 1, true))
  end)
end)

describe("Lab public composition primitives", function()
  it("distinguishes passive outlets from generated defaults and composes playback", function()
    local ui = require("hydronium_lab.controls")
    local outlet = server.renderToString(hydronium.h(ui.ControlsOutlet))
    assert.truthy(outlet:find("data-lab-controls", 1, true))
    assert.falsy(outlet:find("data-lab-default-controls", 1, true))
    local defaults = server.renderToString(hydronium.h(ui.DefaultControls))
    assert.truthy(defaults:find("data-lab-default-controls", 1, true))
    local playback = server.renderToString(hydronium.h("div", nil,
      hydronium.h(ui.PlayPause), hydronium.h(ui.FrameStep), hydronium.h(ui.TimeDisplay)))
    assert.truthy(playback:find("data-lab-play", 1, true))
    assert.truthy(playback:find("data-lab-step", 1, true))
    assert.truthy(playback:find("data-lab-time", 1, true))
    assert.falsy(playback:find("data-lab-restart", 1, true))
    assert.equal(require("hydronium_lab.workbench").ControlsOutlet, ui.ControlsOutlet)
  end)
end)
