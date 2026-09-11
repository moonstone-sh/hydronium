--[[
  Tests for hydronium_router.href.

  This primitive exists to convert a whole class of silent runtime 404s
  into loud call-time errors, so most of this file is about the ERRORS.
  The unknown-key group is the important one: `{ userId = 7 }` against a
  route declaring `:id` is the classic typo, and without that check it
  builds a plausible-looking "/users/" that fails far from its cause.
--]]

local h = require("tests.runner")
local describe, it, assert = h.describe, h.it, h.assert

local matcher = require("hydronium_router.matcher")
local href_mod = require("hydronium_router.href")
local href = href_mod.href

describe("Router: href", function()

  local function fixture()
    local m = matcher.new()
    m:add("home", "/")
    m:add("about", "/about/us")
    m:add("users.show", "/users/:id")
    m:add("users.tab", "/users/:id/:tab")
    m:add("files", "/files/:rest*")
    m:add("assets", "/assets/*")
    return m
  end

  describe("building", function()
    it("builds a static path", function()
      assert.equal(href(fixture(), "home"), "/")
      assert.equal(href(fixture(), "about"), "/about/us")
    end)

    it("substitutes a single param", function()
      assert.equal(href(fixture(), "users.show", { id = 7 }), "/users/7")
    end)

    it("substitutes multiple params", function()
      assert.equal(href(fixture(), "users.tab", { id = 7, tab = "settings" }),
        "/users/7/settings")
    end)

    it("tostrings non-string values", function()
      assert.equal(href(fixture(), "users.show", { id = 42 }), "/users/42")
      assert.equal(href(fixture(), "users.show", { id = true }), "/users/true")
    end)

    it("percent-encodes param values", function()
      assert.equal(href(fixture(), "users.show", { id = "a b" }), "/users/a%20b")
      assert.equal(href(fixture(), "users.show", { id = "a/b" }), "/users/a%2Fb")
    end)

    it("emits literal segments verbatim rather than re-encoding them", function()
      local m = matcher.new()
      m:add("pre", "/caf%C3%A9/x")
      assert.equal(href(m, "pre"), "/caf%C3%A9/x")
    end)

    it("round-trips back through the matcher", function()
      local m = fixture()
      local link = href(m, "users.show", { id = "a b/c" })
      assert.same(m:match(link).params, { id = "a b/c" })
    end)

    it("is callable directly on the module", function()
      assert.equal(href_mod(fixture(), "users.show", { id = 7 }), "/users/7")
    end)
  end)

  describe("catch-all encoding", function()
    --- A catch-all's internal "/" characters are STRUCTURAL -- they
    --- separate real path segments. Encoding the whole value would turn
    --- "a/b" into the single segment "a%2Fb", the exact opposite of what
    --- a catch-all means.
    it("preserves internal slashes while encoding the pieces", function()
      assert.equal(href(fixture(), "files", { rest = "a/b c" }), "/files/a/b%20c")
      assert.equal(href(fixture(), "files", { rest = "x/y/z" }), "/files/x/y/z")
    end)

    it("builds the bare prefix from an empty catch-all, with no trailing slash", function()
      assert.equal(href(fixture(), "files", { rest = "" }), "/files")
    end)

    it("accepts the '*' key for an anonymous wildcard route", function()
      assert.equal(href(fixture(), "assets", { ["*"] = "img/logo.png" }),
        "/assets/img/logo.png")
    end)

    it("round-trips a catch-all through the matcher", function()
      local m = fixture()
      assert.same(m:match(href(m, "files", { rest = "a/b c" })).params, { rest = "a/b c" })
    end)
  end)

  describe("query strings", function()
    it("appends a query with sorted keys", function()
      assert.equal(href(fixture(), "users.show", { id = 7 }, { z = "1", a = "2" }),
        "/users/7?a=2&z=1")
    end)

    it("omits the ? for an empty query table", function()
      assert.equal(href(fixture(), "users.show", { id = 7 }, {}), "/users/7")
    end)

    it("appends a query to a static route", function()
      assert.equal(href(fixture(), "home", nil, { q = "hi there" }), "/?q=hi%20there")
    end)
  end)

  describe("errors", function()
    it("rejects an unknown route id and lists the known ones", function()
      local ok, err = pcall(href, fixture(), "users.shwo")
      assert.falsy(ok)
      err = tostring(err)
      assert.truthy(err:find("unknown route id", 1, true), err)
      assert.truthy(err:find("users.shwo", 1, true), err)
      assert.truthy(err:find("\"users.show\"", 1, true),
        "error should list the known ids so the typo is obvious: " .. err)
    end)

    it("says so clearly when no routes are registered at all", function()
      assert.has_error(function() href(matcher.new(), "anything") end,
        "no routes are registered")
    end)

    it("rejects a missing required param, naming it and the route", function()
      local ok, err = pcall(href, fixture(), "users.show", {})
      assert.falsy(ok)
      err = tostring(err)
      assert.truthy(err:find("missing required param", 1, true), err)
      assert.truthy(err:find("\"id\"", 1, true), err)
      assert.truthy(err:find("/users/:id", 1, true), err)
    end)

    it("rejects a missing param when only some are supplied", function()
      assert.has_error(function() href(fixture(), "users.tab", { id = 7 }) end,
        "missing required param")
    end)

    it("rejects a missing catch-all, pointing at \"\" as the way to omit it", function()
      local ok, err = pcall(href, fixture(), "files", {})
      assert.falsy(ok)
      err = tostring(err)
      assert.truthy(err:find("missing required catch%-all param"), err)
      assert.truthy(err:find("no trailing segments", 1, true), err)
    end)

    --- The reason this module exists.
    it("rejects an unknown param key and lists the accepted names", function()
      local ok, err = pcall(href, fixture(), "users.show", { userId = 7 })
      assert.falsy(ok)
      err = tostring(err)
      assert.truthy(err:find("unknown param key", 1, true), err)
      assert.truthy(err:find("userId", 1, true), err)
      assert.truthy(err:find("accepted param names: id", 1, true), err)
    end)

    it("rejects unknown keys even when every required param IS present", function()
      assert.has_error(function()
        href(fixture(), "users.show", { id = 7, tab = "oops" })
      end, "unknown param key")
    end)

    it("lists every unknown key, sorted", function()
      local ok, err = pcall(href, fixture(), "users.show", { id = 1, zz = 2, aa = 3 })
      assert.falsy(ok)
      assert.truthy(tostring(err):find("aa, zz", 1, true), tostring(err))
    end)

    it("says a static route takes no params", function()
      assert.has_error(function() href(fixture(), "about", { id = 1 }) end,
        "this route takes no params")
    end)

    it("rejects a non-table params argument", function()
      assert.has_error(function() href(fixture(), "home", "id=1") end,
        "params must be a table")
    end)

    it("rejects a non-table route source", function()
      assert.has_error(function() href("not a matcher", "home") end,
        "expected a Matcher or a route table")
    end)
  end)

  describe("plain route tables", function()
    --- Usable without standing up a whole Matcher, so a script or a test
    --- can build links from a literal table.
    it("accepts a table mapping id -> pattern string", function()
      local routes = { ["users.show"] = "/users/:id" }
      assert.equal(href(routes, "users.show", { id = 7 }), "/users/7")
    end)

    it("accepts a table mapping id -> record with a path", function()
      local routes = { ["users.show"] = { path = "/users/:id" } }
      assert.equal(href(routes, "users.show", { id = 7 }), "/users/7")
    end)

    it("still validates unknown keys against a plain table", function()
      assert.has_error(function()
        href({ ["users.show"] = "/users/:id" }, "users.show", { userId = 7 })
      end, "unknown param key")
    end)

    it("lists the plain table's ids on an unknown id", function()
      assert.has_error(function()
        href({ a = "/a", b = "/b" }, "c")
      end, "known ids: \"a\", \"b\"")
    end)
  end)

end)
