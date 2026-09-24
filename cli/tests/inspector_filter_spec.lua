--[[
  The filter bar end to end: typing narrows the real fullscreen request list,
  rendered through the real ink host.
--]]

local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert

local hydronium = require("hydronium")
local session = require("hydronium_ink.session")
local ui = require("ui.app")
local inspector_view = require("ui.inspector_view")
local search_field = require("ui.search_field")

local function req(method, path, status)
  return {
    v = 1, source = "meteorite", kind = "request", ts = 1,
    method = method, path = path, status = status, duration_ms = 5,
  }
end

--- Renders the fullscreen view with `filter` typed into the bar and returns
--- the painted rows as plain text.
local function rows(filter)
  local state = ui.new_state({})
  state:record_request(req("GET", "/api/users", 200))
  state:record_request(req("POST", "/api/login", 401))
  state:record_request(req("GET", "/health", 200))
  state.set_search(search_field.new_state(filter))
  state.set_search_revision(state.search_revision() + 1)

  local View = inspector_view.create_view(state)
  local s = session.create(hydronium.h(View),
    { writeFn = function() end, columns = 90, rows = 20, color = "ansi16" })
  s:step()
  local frame = s:frame()
  local out = {}
  for y = 1, frame.h do
    local chars = {}
    for x = 1, frame.w do chars[x] = frame.rows[y][x].ch end
    out[y] = table.concat(chars)
  end
  s:close()
  return table.concat(out, "\n")
end

local function shows(text, needle)
  return text:find(needle, 1, true) ~= nil
end

describe("hydronium_cli fullscreen view -- filtering", function()
  it("shows everything with an empty filter", function()
    local text = rows("")
    assert.truthy(shows(text, "/api/users"))
    assert.truthy(shows(text, "/api/login"))
    assert.truthy(shows(text, "/health"))
  end)

  it("narrows by method", function()
    local text = rows("method:POST")
    assert.truthy(shows(text, "/api/login"), "POST row must survive:\n" .. text)
    assert.falsy(shows(text, "/api/users"), "GET rows must be filtered out:\n" .. text)
    assert.falsy(shows(text, "/health"))
  end)

  it("excludes with a negated tag", function()
    local text = rows("-method:GET")
    assert.truthy(shows(text, "/api/login"))
    assert.falsy(shows(text, "/health"))
  end)

  it("ORs a repeated field and ANDs across fields", function()
    assert.truthy(shows(rows("method:GET method:POST"), "/api/login"))
    assert.truthy(shows(rows("method:GET method:POST"), "/health"))
    local both = rows("method:GET path:/api")
    assert.truthy(shows(both, "/api/users"))
    assert.falsy(shows(both, "/health"), "path:/api must exclude /health:\n" .. both)
  end)

  it("filters by status class", function()
    local text = rows("status:4xx")
    assert.truthy(shows(text, "/api/login"))
    assert.falsy(shows(text, "/api/users"))
  end)

  it("reports that the list is filtered rather than looking empty", function()
    local text = rows("method:POST")
    assert.truthy(shows(text, "filtered from 3"),
      "the header must say the list is filtered:\n" .. text)
  end)

  it("matches free text against the whole request", function()
    local text = rows("health")
    assert.truthy(shows(text, "/health"))
    assert.falsy(shows(text, "/api/users"))
  end)
end)
