--[[
  hydronium_cli.query -- the fullscreen view's filter language.
--]]

local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert

local query = require("query")

local function req(over)
  local e = {
    kind = "request", method = "GET", path = "/api/users", status = 200,
    duration_ms = 12, remote_addr = "127.0.0.1",
    -- The REAL wire shape: meteorite emits an ARRAY of {name,value} pairs,
    -- never a map, because order and duplicates are meaningful in HTTP
    -- (zig/server/dev_events.zig says so explicitly). Fixtures used a map
    -- until this was checked against the emitter, and every header-derived
    -- field silently matched nothing.
    headers = {
      { name = "Content-Type", value = "application/json" },
      { name = "Origin", value = "http://localhost:5174" },
      { name = "Set-Cookie", value = "a=1" },
      { name = "Set-Cookie", value = "b=2" },
      { name = "Authorization", value = "[redacted]" },
    },
    body = '{"message":"user not found"}',
  }
  for k, v in pairs(over or {}) do e[k] = v end
  return e
end

local function matches(text, event)
  return query.matches(event, query.parse(text))
end

describe("hydronium_cli.query -- merging semantics", function()
  it("ANDs across different fields", function()
    assert.equal(matches("method:GET status:200", req()), true)
    assert.equal(matches("method:GET status:404", req()), false)
  end)

  it("ORs within a repeated field", function()
    assert.equal(matches("method:GET method:POST", req()), true)
    assert.equal(matches("method:GET method:POST", req({ method = "POST" })), true)
    assert.equal(matches("method:GET method:POST", req({ method = "DELETE" })), false)
  end)

  it("excludes with a leading dash", function()
    assert.equal(matches("-method:POST", req()), true)
    assert.equal(matches("-method:GET", req()), false)
  end)

  it("combines include and exclude", function()
    assert.equal(matches("path:/api -status:5xx", req()), true)
    assert.equal(matches("path:/api -status:2xx", req()), false)
  end)

  it("treats an empty query as matching everything", function()
    assert.equal(matches("", req()), true)
    assert.equal(matches("   ", req()), true)
  end)
end)

describe("hydronium_cli.query -- per-field match strategies", function()
  it("matches status classes as well as exact codes", function()
    assert.equal(matches("status:2xx", req()), true)
    assert.equal(matches("status:4xx", req()), false)
    assert.equal(matches("status:200", req()), true)
    assert.equal(matches("status:404", req({ status = 404 })), true)
    assert.equal(matches("status:4xx", req({ status = 404 })), true)
  end)

  it("compares durations numerically", function()
    assert.equal(matches("duration:>10", req()), true)
    assert.equal(matches("duration:>100", req()), false)
    assert.equal(matches("duration:<20", req()), true)
    assert.equal(matches("duration:>=12", req()), true)
    assert.equal(matches("duration:12", req()), true)
  end)

  it("matches method exactly, not by substring or trigram", function()
    -- The reason method is NOT trigram-matched: these share trigrams and
    -- must not match each other.
    assert.equal(matches("method:GET", req({ method = "DELETE" })), false)
    assert.equal(matches("method:DELETE", req({ method = "DELETE" })), true)
    -- Case-insensitive, because nobody types uppercase in a filter bar.
    assert.equal(matches("method:get", req()), true)
  end)

  it("reads mime and origin out of real headers", function()
    assert.equal(matches("mime:json", req()), true)
    assert.equal(matches("mime:html", req()), false)
    assert.equal(matches("origin:5174", req()), true)
  end)

  it("still reads a map, for any emitter that sends one", function()
    -- normalize_headers accepts both shapes; this proves the fallback path
    -- rather than assuming it.
    local mapped = req({ headers = { ["Content-Type"] = "text/html" } })
    assert.equal(matches("mime:html", mapped), true)
  end)

  it("finds a repeated header, which a map could not represent", function()
    assert.equal(matches("header:set-cookie=b=2", req()), true)
    assert.equal(matches("header:set-cookie=zzz", req()), false)
  end)

  it("can filter on a redacted header being present", function()
    -- Meteorite always redacts authorization/cookie values but KEEPS the
    -- header, so "was this request authenticated at all" stays answerable.
    assert.equal(matches("header:authorization", req()), true)
    assert.equal(matches("header:authorization=[redacted]", req()), true)
  end)

  it("matches headers by name, or by name=value", function()
    assert.equal(matches("header:content-type", req()), true)
    assert.equal(matches("header:content-type=json", req()), true)
    assert.equal(matches("header:content-type=html", req()), false)
    assert.equal(matches("header:x-missing", req()), false)
  end)

  it("uses trigram similarity for bodies, tolerating a typo", function()
    assert.equal(matches('body:"user not found"', req()), true)
    -- One transposed character still finds it -- the point of trigrams.
    assert.equal(matches('body:"user not fuond"', req()), true)
    -- Something genuinely absent still does not match.
    assert.equal(matches("body:unauthorized", req()), false)
  end)

  it("does not match a body that meteorite measured but did not include", function()
    -- A body over max_body_bytes, or not valid UTF-8, is emitted as
    -- `body_bytes` with no `body` at all (zig/server/dev_events.zig). That is
    -- "measured but not captured", and must not be treated as an empty body
    -- that matches nothing-in-particular.
    local measured = req({ body = nil, body_bytes = 40000 })
    assert.equal(matches("body:anything", measured), false)
    -- And a request whose body was never read at all.
    local unread = req({ body = nil })
    assert.equal(matches("body:anything", unread), false)
    -- The rest of the request is still filterable.
    assert.equal(matches("method:GET", measured), true)
  end)

  it("falls back to substring for a body query too short to have trigrams", function()
    assert.equal(matches("body:us", req()), true)
    assert.equal(matches("body:zz", req()), false)
  end)
end)

describe("hydronium_cli.query -- tokenizing for the UI", function()
  it("reports positions so the field can render chips in place", function()
    local tokens = query.tokenize("method:GET free -status:5xx")
    assert.equal(#tokens, 3)
    assert.equal(tokens[1].type, "tag")
    assert.equal(tokens[1].field, "method")
    assert.equal(tokens[1].value, "GET")
    assert.equal(tokens[1].from, 1)
    assert.equal(tokens[1].to, 10)
    assert.equal(tokens[2].type, "text")
    assert.equal(tokens[3].type, "tag")
    assert.equal(tokens[3].negated, true)
  end)

  it("marks an unrecognised field as unknown rather than dropping it", function()
    local tokens = query.tokenize("nope:1")
    assert.equal(tokens[1].type, "unknown")
    -- And it still narrows, as free text, instead of matching nothing.
    assert.equal(matches("nope:1", req()), false)
    assert.equal(matches("users", req()), true)
  end)

  it("keeps a quoted value as one token", function()
    local tokens = query.tokenize('body:"not found" method:GET')
    assert.equal(#tokens, 2)
    assert.equal(tokens[1].value, "not found")
  end)

  it("tolerates a half-typed tag while the user is still typing", function()
    -- Mid-typing states must never raise.
    for _, partial in ipairs({ "m", "me", "method", "method:", "-", "-method:", 'body:"' }) do
      local ok = pcall(query.parse, partial)
      assert.truthy(ok, "parse must not raise on " .. string.format("%q", partial))
    end
  end)
end)

describe("hydronium_cli.query -- against a REAL meteorite event line", function()
  local event_model = require("event_model")

  -- Captured verbatim from .meteorite/dev/events.log with meteorite 0.2.9
  -- serving a real request. Kept as a golden fixture because every other
  -- fixture in this file is synthetic, and a synthetic fixture only proves
  -- the code agrees with the assumption it was written from -- which is
  -- exactly how mime:/origin:/header: shipped matching nothing.
  local REAL_LINE = [==[{"v":1,"ts":1790257345229,"source":"server","kind":"request","method":"GET","path":"/","status":200,"duration_ms":36.999,"remote_addr":"127.0.0.1","headers":[{"name":"Host","value":"127.0.0.1:8080"},{"name":"User-Agent","value":"curl/8.7.1"},{"name":"Accept","value":"*/*"},{"name":"X-Probe","value":"hydronium"},{"name":"Authorization","value":"[redacted]"}]}]==]

  local function real_event()
    local event, why = event_model.parse_line(REAL_LINE)
    assert.truthy(event, "the recorded line must still parse: " .. tostring(why))
    return event
  end

  local function m(filter)
    return query.matches(real_event(), query.parse(filter))
  end

  it("parses as a request with the envelope fields", function()
    local e = real_event()
    assert.equal(e.kind, "request")
    assert.equal(e.method, "GET")
    assert.equal(e.status, 200)
  end)

  it("carries headers as an array of name/value pairs", function()
    local list = event_model.normalize_headers(real_event().headers)
    assert.truthy(list and #list > 0, "0.2.9 emits headers; a bare five-field line means an older meteorite")
    assert.equal(type(list[1].name), "string")
    assert.equal(type(list[1].value), "string")
  end)

  it("filters on a real header, by name and by name=value", function()
    assert.equal(m("header:x-probe"), true)
    assert.equal(m("header:x-probe=hydronium"), true)
    assert.equal(m("header:x-probe=nope"), false)
    assert.equal(m("header:user-agent=curl"), true)
  end)

  it("sees a redacted header as present", function()
    -- Meteorite replaces the value but keeps the header, so "was this
    -- authenticated" stays answerable without the secret being on disk.
    assert.equal(m("header:authorization"), true)
    local list = event_model.normalize_headers(real_event().headers)
    for _, h in ipairs(list) do
      if h.name:lower() == "authorization" then
        assert.equal(h.value, "[redacted]")
      end
    end
  end)

  it("combines tags and negation on the real event", function()
    assert.equal(m("method:GET status:2xx"), true)
    assert.equal(m("-header:x-probe"), false)
    -- A header this request genuinely does not carry.
    assert.equal(m("mime:json"), false)
  end)
end)
