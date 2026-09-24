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
    headers = { ["Content-Type"] = "application/json", Origin = "http://localhost:5174" },
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
