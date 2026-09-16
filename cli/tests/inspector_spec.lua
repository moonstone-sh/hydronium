--[[
  hydronium-cli inspector -- the fullscreen request-debug view's pure half:
  the uncollapsed request history, the selection/scroll-window arithmetic,
  and the row/detail formatting.

  Same contract as event_model's own spec: everything here runs on canned
  events, because the module is pure (no files, no processes, no clock, no
  terminal). The forward-compatibility cases matter most -- meteorite emits
  no headers or bodies today, so the "not captured" placeholders are the
  real behaviour, and the cases that DO pass headers/body prove the same
  code renders them the moment meteorite starts emitting them.
--]]

local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert

local inspector = require("inspector")
local event_model = require("event_model")

--- @param overrides? table
local function request(overrides)
  local event = {
    v = 1,
    ts = 1757000000000,
    source = "server",
    kind = "request",
    method = "GET",
    path = "/home",
    status = 200,
    duration_ms = 47,
    remote_addr = "127.0.0.1",
  }
  for key, value in pairs(overrides or {}) do
    event[key] = value
  end
  return event
end

local function detail_text(lines)
  local out = {}
  for index, line in ipairs(lines) do
    out[index] = line.text
  end
  return table.concat(out, "\n")
end

describe("hydronium-cli inspector -- history", function()
  it("keeps request events and ignores every other kind", function()
    local history = inspector.new_history()
    assert.truthy(history:push(request()))
    assert.falsy(history:push({ kind = "reload", ok = true, ts = 1 }))
    assert.falsy(history:push({ kind = "startup", ts = 1 }))
    assert.falsy(history:push({ kind = "build_error", ts = 1 }))
    assert.equal(history:count(), 1)
  end)

  it("does not collapse consecutive identical requests the way the display buffer does", function()
    -- The whole reason this history exists next to event_model's ring: the
    -- collapsed pane would render these as one "GET /home x4" row, and the
    -- request you are debugging is usually one of the folded-away ones.
    local history = inspector.new_history()
    for i = 1, 4 do
      history:push(request({ ts = 1757000000000 + i * 10, duration_ms = i }))
    end
    assert.equal(history:count(), 4)
    assert.equal(history:get(1).duration_ms, 1)
    assert.equal(history:get(4).duration_ms, 4)

    local collapsed = event_model.new_buffer()
    for i = 1, 4 do
      collapsed:push(request({ ts = 1757000000000 + i * 10, duration_ms = i }))
    end
    assert.equal(#collapsed:lines(), 1, "the display buffer really does collapse these into one row")
  end)

  it("drops the oldest rows past its capacity and counts what it dropped", function()
    local history = inspector.new_history({ capacity = 3 })
    for i = 1, 5 do
      history:push(request({ path = "/p" .. i }))
    end
    assert.equal(history:count(), 3)
    assert.equal(history.dropped, 2)
    assert.equal(history:get(1).path, "/p3")
    assert.equal(history:get(3).path, "/p5")
  end)

  it("slices a visible window, clamped to what exists", function()
    local history = inspector.new_history()
    for i = 1, 5 do
      history:push(request({ path = "/p" .. i }))
    end
    local rows = history:slice(4, 9)
    assert.equal(#rows, 2)
    assert.equal(rows[1].index, 4)
    assert.equal(rows[1].event.path, "/p4")
    assert.equal(rows[2].index, 5)
  end)

  it("rejects a nonsensical capacity loudly", function()
    assert.has_error(function()
      inspector.new_history({ capacity = 0 })
    end, "capacity")
  end)
end)

describe("hydronium-cli inspector -- selection and scroll window", function()
  it("clamps the selection at both ends and reports 0 for an empty list", function()
    assert.equal(inspector.clamp_selection(5, 0), 0)
    assert.equal(inspector.clamp_selection(0, 10), 1)
    assert.equal(inspector.clamp_selection(99, 10), 10)
    assert.equal(inspector.clamp_selection(4, 10), 4)
  end)

  it("moves the selection without wrapping", function()
    assert.equal(inspector.move_selection(1, -1, 10), 1, "already at the oldest row: stays")
    assert.equal(inspector.move_selection(10, 1, 10), 10, "already at the newest row: stays")
    assert.equal(inspector.move_selection(5, 3, 10), 8)
    assert.equal(inspector.move_selection(5, -50, 10), 1)
    assert.equal(inspector.move_selection(0, 1, 0), 0, "nothing to select")
  end)

  it("follows the tail only while the selection already was the tail", function()
    -- Pinned to the newest row: new traffic keeps it pinned.
    assert.equal(inspector.follow_tail(10, 10, 12, 0), 12)
    -- Reading an older row: new traffic must not yank it away.
    assert.equal(inspector.follow_tail(4, 10, 12, 0), 4)
    -- Nothing selected yet: default to the newest row.
    assert.equal(inspector.follow_tail(0, 0, 3, 0), 3)
    -- Eviction shifted every row down by 2, so the same event keeps the
    -- selection.
    assert.equal(inspector.follow_tail(6, 10, 10, 2), 4)
  end)

  it("windows a list longer than the viewport, keeping the selection visible and never running off the end", function()
    local first, last = inspector.window(100, 50, 10)
    assert.truthy(first <= 50 and 50 <= last, "the selected row must be inside the window")
    assert.equal(last - first + 1, 10, "a full viewport must be filled")

    first, last = inspector.window(100, 1, 10)
    assert.equal(first, 1)
    assert.equal(last, 10)

    first, last = inspector.window(100, 100, 10)
    assert.equal(last, 100, "the newest row must be reachable")
    assert.equal(first, 91, "and the window must not run past the end into blank rows")

    first, last = inspector.window(4, 2, 10)
    assert.equal(first, 1)
    assert.equal(last, 4, "a short list is shown whole, not padded")

    first, last = inspector.window(0, 0, 10)
    assert.equal(first, 1)
    assert.equal(last, 0, "an empty list yields an empty slice")
  end)

  it("pages by a screen minus one row of overlap", function()
    assert.equal(inspector.page_size(20), 19)
    assert.equal(inspector.page_size(1), 1, "never zero -- paging must always move")
  end)
end)

describe("hydronium-cli inspector -- rows", function()
  it("formats a fixed-width row with a selection marker", function()
    local row = inspector.format_row(request(), { columns = 80, selected = true })
    assert.truthy(row:find("^> GET"), "the selected row is marked: " .. row)
    assert.truthy(row:find("/home", 1, true))
    assert.truthy(row:find("200", 1, true))
    assert.truthy(row:find("47ms", 1, true))
    assert.falsy(row:find("127.0.0.1", 1, true), "remote addresses are opt-in, same as the status view")

    local unselected = inspector.format_row(request(), { columns = 80 })
    assert.truthy(unselected:find("^  GET"), "an unselected row is indented, not marked")
    -- Every string this view paints is ASCII (see inspector.lua's own note
    -- on the host's per-byte cell grid), so byte length IS column width
    -- here and the two rows must match exactly.
    assert.equal(#row, #unselected, "rows must be the same width whether selected or not")
  end)

  it("shows the remote address under show_ips, in the same column as its header", function()
    local row = inspector.format_row(request(), { columns = 100, show_ips = true })
    local header = inspector.header_row(100, { show_ips = true })
    assert.truthy(row:find("127.0.0.1", 1, true))
    assert.truthy(header:find("REMOTE", 1, true))
    assert.equal(header:find("REMOTE", 1, true), row:find("127.0.0.1", 1, true),
      "the value must start in the column its header does")
  end)

  it("truncates a long path to the terminal width instead of wrapping the row", function()
    local long = "/a/" .. string.rep("very-long-segment/", 20)
    local row = inspector.format_row(request({ path = long }), { columns = 80 })
    assert.truthy(#row <= 80, "row was " .. #row .. " columns wide on an 80-column terminal")
    assert.truthy(row:find("...", 1, true), "truncation must be visible")
  end)

  it("renders a request with missing fields rather than erroring on it", function()
    local row = inspector.format_row({ kind = "request", ts = 1 }, { columns = 80, show_ips = true })
    assert.truthy(row:find("?", 1, true), "an absent method/path shows as ?")
    assert.truthy(row:find("-", 1, true), "an absent status/duration shows as -")
  end)

  it("emits pure ASCII, so the host's per-byte cell grid stays aligned with real columns", function()
    -- Not cosmetic: the terminal host paints one grid cell per BYTE and
    -- positions each incremental-diff run by frame column, so one
    -- multi-byte character makes every partial repaint after it land in the
    -- wrong terminal column. Observed live as `8.0.0858 8` where
    -- `8.8.8.8` belonged, back when the row marker and the detail
    -- separators were `\226\150\184` and `\194\183`.
    local function ascii_only(text, what)
      for index = 1, #text do
        assert.truthy(text:byte(index) < 128,
          what .. " must be ASCII, found byte " .. text:byte(index) .. " at " .. index .. ": " .. text)
      end
    end

    ascii_only(inspector.format_row(request(), { columns = 80, selected = true }), "a selected row")
    ascii_only(inspector.format_row(request(), { columns = 80, show_ips = true }), "a row with an address")
    ascii_only(inspector.header_row(80, { show_ips = true }), "the column header")
    for _, line in ipairs(inspector.detail_lines(request(), { columns = 80 })) do
      ascii_only(line.text, "a detail line")
    end
  end)

  it("colors a status by class", function()
    assert.equal(inspector.status_color(200), "green")
    assert.equal(inspector.status_color(302), "cyan")
    assert.equal(inspector.status_color(404), "yellow")
    assert.equal(inspector.status_color(500), "red")
    assert.is_nil(inspector.status_color(nil))
  end)
end)

describe("hydronium-cli inspector -- detail pane", function()
  it("says headers and bodies are NOT CAPTURED, naming the reason, for today's meteorite events", function()
    -- The real, current state: zig/server/dev_events.zig emits
    -- method/path/status/duration_ms/remote_addr and nothing else. "no
    -- headers" would read as "this request had none", which is false.
    local text = detail_text(inspector.detail_lines(request(), { columns = 100 }))
    assert.truthy(text:find("GET /home", 1, true))
    assert.truthy(text:find("127.0.0.1", 1, true))
    assert.truthy(text:find("headers: not captured", 1, true), text)
    assert.truthy(text:find("body: not captured", 1, true), text)
    assert.truthy(text:find("meteorite", 1, true), "the placeholder must say whose gap this is")
  end)

  it("renders real headers and a real body the moment an event carries them", function()
    -- FORWARD COMPATIBILITY, proven rather than asserted: this is the
    -- event shape a later meteorite would emit, and the same code path
    -- renders it with no redesign.
    local event = request({
      headers = { ["content-type"] = "text/html", accept = "*/*" },
      body = "<h1>hello</h1>\nsecond line",
    })
    local text = detail_text(inspector.detail_lines(event, { columns = 100 }))
    assert.falsy(text:find("not captured", 1, true), "the placeholder must be gone: " .. text)
    assert.truthy(text:find("accept: */*", 1, true), text)
    assert.truthy(text:find("content%-type: text/html"), text)
    assert.truthy(text:find("<h1>hello</h1>", 1, true), text)
    assert.truthy(text:find("second line", 1, true), text)
    assert.truthy(text:find("26 bytes", 1, true), "a body's size must be reported: " .. text)
  end)

  it("caps a long body and marks the cut", function()
    local event = request({ body = "1\n2\n3\n4\n5\n6\n7\n8" })
    local text = detail_text(inspector.detail_lines(event, { columns = 100, body_lines = 3 }))
    assert.truthy(text:find("\n%s*%.%.%."), "the elision marker must be present: " .. text)
    assert.falsy(text:find("\n%s*8\n"), "lines past the cap must not be rendered")
  end)

  it("distinguishes a body meteorite measured but did not include", function()
    local text = detail_text(inspector.detail_lines(request({ body_bytes = 4096 }), { columns = 100 }))
    assert.truthy(text:find("4096 bytes", 1, true), text)
    assert.truthy(text:find("content not included", 1, true), text)
  end)

  it("distinguishes captured-but-empty headers from absent ones", function()
    local text = detail_text(inspector.detail_lines(request({ headers = {} }), { columns = 100 }))
    assert.truthy(text:find("captured, none present", 1, true), text)
    assert.falsy(text:find("headers: not captured", 1, true))
  end)

  it("says so plainly when nothing has been captured at all", function()
    local text = detail_text(inspector.detail_lines(nil, { columns = 100 }))
    assert.truthy(text:find("no requests captured yet", 1, true))
  end)

  it("reports a missing remote_addr as not reported rather than inventing one", function()
    -- Cleared after construction: a nil in the overrides table is not a
    -- removal, it is simply an absent key the loop never sees.
    local event = request()
    event.remote_addr = nil
    local text = detail_text(inspector.detail_lines(event, { columns = 100 }))
    assert.truthy(text:find("remote_addr not reported", 1, true), text)
  end)
end)

describe("hydronium-cli event_model -- request_detail", function()
  it("reports has_headers/has_body false for a real current-meteorite event", function()
    local detail = event_model.request_detail(request())
    assert.falsy(detail.has_headers)
    assert.falsy(detail.has_body)
    assert.is_nil(detail.headers)
    assert.is_nil(detail.body)
    assert.equal(detail.method, "GET")
    assert.equal(detail.status, 200)
    assert.equal(detail.duration_ms, 47)
    assert.equal(detail.remote_addr, "127.0.0.1")
  end)

  it("normalizes every plausible header shape a later emitter could use", function()
    local from_map = event_model.request_detail(request({ headers = { b = "2", a = "1" } }))
    assert.truthy(from_map.has_headers)
    assert.same(from_map.headers, { { name = "a", value = "1" }, { name = "b", value = "2" } })

    local from_objects = event_model.request_detail(request({
      headers = { { name = "set-cookie", value = "a=1" }, { name = "set-cookie", value = "b=2" } },
    }))
    assert.equal(#from_objects.headers, 2, "repeated headers must survive -- their order is meaningful")
    assert.equal(from_objects.headers[2].value, "b=2")

    local from_pairs = event_model.request_detail(request({ headers = { { "accept", "*/*" } } }))
    assert.same(from_pairs.headers, { { name = "accept", value = "*/*" } })
  end)

  it("measures a body it was given and trusts a size it was told", function()
    assert.equal(event_model.request_detail(request({ body = "abcd" })).body_bytes, 4)
    local told = event_model.request_detail(request({ body_bytes = 99 }))
    assert.equal(told.body_bytes, 99)
    assert.truthy(told.has_body)
    assert.is_nil(told.body)
  end)

  it("is_request only accepts request events", function()
    assert.truthy(event_model.is_request(request()))
    assert.falsy(event_model.is_request({ kind = "reload" }))
    assert.falsy(event_model.is_request(nil))
    assert.falsy(event_model.is_request("request"))
  end)
end)
