--[[
  Tests for hydronium_router.pattern -- route-pattern parsing and
  specificity comparison.

  The grammar under test is deliberately identical to Meteorite's own
  (`meteorite/src/core/route.lua`'s `parse_path`), so the reject cases
  below are as much a compatibility check as a validation check: a path
  that is illegal on the server must be illegal here too.
--]]

local h = require("tests.runner")
local describe, it, assert = h.describe, h.it, h.assert

local pattern = require("hydronium_router.pattern")

--- io.open with a clear failure instead of a nil-index error if the file
--- ever moves. Local, not global: this repo has an isolation spec that
--- treats stray globals as pollution.
local function open_source(path)
  local f = io.open(path, "r")
  if not f then
    assert.fail("could not open " .. path .. " (run the suite from the repo root)")
  end
  return f
end

describe("Router: pattern", function()

  describe("parsing", function()
    it("parses the root pattern as zero segments", function()
      local p = pattern.parse("/")
      assert.equal(p.source, "/")
      assert.equal(#p.segments, 0)
      assert.equal(#p.params, 0)
      assert.truthy(p.is_static)
      assert.falsy(p.has_catch_all)
    end)

    it("parses literal segments", function()
      local p = pattern.parse("/users/settings")
      assert.equal(#p.segments, 2)
      assert.equal(p.segments[1].kind, "literal")
      assert.equal(p.segments[1].value, "users")
      assert.equal(p.segments[2].value, "settings")
      assert.truthy(p.is_static)
    end)

    it("parses a single-segment param", function()
      local p = pattern.parse("/users/:id")
      assert.equal(p.segments[2].kind, "param")
      assert.equal(p.segments[2].name, "id")
      assert.same(p.params, { "id" })
      assert.falsy(p.is_static)
      assert.falsy(p.has_catch_all)
    end)

    it("parses a named catch-all as its own kind", function()
      local p = pattern.parse("/files/:rest*")
      assert.equal(p.segments[2].kind, "catch_all")
      assert.equal(p.segments[2].name, "rest")
      assert.same(p.params, { "rest" })
      assert.truthy(p.has_catch_all)
      assert.falsy(p.has_wildcard)
    end)

    it("parses an anonymous wildcard, which is not a named param", function()
      local p = pattern.parse("/assets/*")
      assert.equal(p.segments[2].kind, "wildcard")
      assert.is_nil(p.segments[2].name)
      assert.same(p.params, {})
      assert.truthy(p.has_catch_all)
      assert.truthy(p.has_wildcard)
    end)

    it("records params in declaration order", function()
      local p = pattern.parse("/:org/repos/:repo/blob/:ref*")
      assert.same(p.params, { "org", "repo", "ref" })
    end)

    it("scores each segment by specificity", function()
      local p = pattern.parse("/a/:b/*")
      assert.same(p.scores, {
        pattern.SCORE_LITERAL,
        pattern.SCORE_PARAM,
        pattern.SCORE_CATCH_ALL,
      })
      assert.same(p.scores, { 3, 2, 1 })
    end)

    it("accepts underscore-prefixed and digit-containing param names", function()
      local p = pattern.parse("/:_private/:v2")
      assert.same(p.params, { "_private", "v2" })
    end)
  end)

  describe("rejections", function()
    it("rejects a non-string pattern", function()
      assert.has_error(function() pattern.parse(42) end, "must be a string")
    end)

    it("rejects an empty pattern", function()
      assert.has_error(function() pattern.parse("") end, "non%-empty")
    end)

    it("rejects a pattern with no leading slash", function()
      assert.has_error(function() pattern.parse("users/:id") end, "must start with")
    end)

    it("rejects an invalid param name", function()
      assert.has_error(function() pattern.parse("/users/:2id") end, "invalid path param name")
      assert.has_error(function() pattern.parse("/users/:my-id") end, "invalid path param name")
      assert.has_error(function() pattern.parse("/users/:") end, "invalid path param name")
    end)

    it("rejects a duplicate param name within one pattern", function()
      assert.has_error(function() pattern.parse("/:id/x/:id") end, "duplicate path param name")
    end)

    it("rejects a non-final catch-all", function()
      assert.has_error(function() pattern.parse("/files/:rest*/edit") end, "must be the final segment")
    end)

    it("rejects a non-final wildcard", function()
      assert.has_error(function() pattern.parse("/assets/*/edit") end, "must be the final segment")
    end)

    --- Meteorite's own "must be final" check compares the segment string
    --- to `path:match("[^/]+$")`, which cannot distinguish two IDENTICAL
    --- trailing segments -- "/a/*/*" passes that check because the first
    --- "*" is string-equal to the last one. The extra "nothing may follow
    --- a catch-all" guard is what actually catches it.
    it("rejects a segment following a catch-all even when the strings are identical", function()
      assert.has_error(function() pattern.parse("/a/*/*") end,
        "no segment may follow a catch%-all")
      assert.has_error(function() pattern.parse("/a/:r*/:r*") end,
        "no segment may follow a catch%-all")
    end)

    it("rejects '*' used inside a literal segment", function()
      assert.has_error(function() pattern.parse("/a*b") end, "only allowed as a whole segment")
    end)
  end)

  describe("more_specific", function()
    it("prefers a literal over a param at the same position", function()
      local lit = pattern.parse("/users/me")
      local par = pattern.parse("/users/:id")
      assert.truthy(pattern.more_specific(lit, par))
      assert.falsy(pattern.more_specific(par, lit))
    end)

    it("prefers a param over a catch-all at the same position", function()
      local par = pattern.parse("/files/:name")
      local cat = pattern.parse("/files/:rest*")
      assert.truthy(pattern.more_specific(par, cat))
      assert.falsy(pattern.more_specific(cat, par))
    end)

    it("compares left to right, so an earlier difference decides", function()
      -- b is more specific at index 2, but a wins at index 1.
      local a = pattern.parse("/x/:p/:q")
      local b = pattern.parse("/:v/y/z")
      assert.truthy(pattern.more_specific(a, b))
      assert.falsy(pattern.more_specific(b, a))
    end)

    it("breaks a full prefix tie by putting the longer pattern first", function()
      local short = pattern.parse("/a")
      local long = pattern.parse("/a/b")
      assert.truthy(pattern.more_specific(long, short))
      assert.falsy(pattern.more_specific(short, long))
    end)

    it("reports an exact tie as false in BOTH directions", function()
      -- This is what lets the matcher layer declaration order on top and
      -- still have a total order.
      local a = pattern.parse("/:a/:b")
      local b = pattern.parse("/:c/:d")
      assert.falsy(pattern.more_specific(a, b))
      assert.falsy(pattern.more_specific(b, a))
    end)
  end)

  describe("purity", function()
    --- pattern.lua is the bottom of the router's dependency graph and
    --- must stay loadable with nothing else present.
    it("has no require calls in its source", function()
      local f = open_source("router/src/hydronium_router/pattern.lua")
      local src = f:read("*a")
      f:close()
      -- Ignore the module doc comment; look at code only.
      local code = src:gsub("^%-%-%[%[.-%-%-%]%]", "")
      assert.is_nil(code:find("require", 1, true),
        "pattern.lua must have zero require calls")
    end)
  end)

end)
