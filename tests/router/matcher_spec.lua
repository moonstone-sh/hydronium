--[[
  Tests for hydronium_router.matcher.

  The centrepiece here is the declaration-order-independence group. Lua's
  `table.sort` is NOT stable, and route resolution that silently depends
  on the sort algorithm's partitioning (or on `pairs` iteration order)
  is the kind of bug that reproduces on one machine and not another. The
  matcher defends against that with an explicit insertion counter used as
  the comparator's final tiebreaker; the tests below pin the resulting
  behaviour from the outside.
--]]

local h = require("tests.runner")
local describe, it, assert = h.describe, h.it, h.assert

local matcher = require("hydronium_router.matcher")

describe("Router: matcher", function()

  describe("registration", function()
    it("accepts dot-separated identifier ids", function()
      local m = matcher.new()
      m:add("home", "/")
      m:add("users.show", "/users/:id")
      m:add("admin.users.edit", "/admin/users/:id/edit")
      m:add("_private", "/p")
      assert.same(m:ids(), { "_private", "admin.users.edit", "home", "users.show" })
    end)

    it("returns the stored route record from add", function()
      local m = matcher.new()
      local r = m:add("users.show", "/users/:id", { title = "User" })
      assert.equal(r.id, "users.show")
      assert.equal(r.path, "/users/:id")
      assert.equal(r.meta.title, "User")
      assert.equal(m:get("users.show"), r)
    end)

    it("returns nil from get for an unregistered id", function()
      assert.is_nil(matcher.new():get("nope"))
    end)

    it("rejects an invalid route id", function()
      local m = matcher.new()
      assert.has_error(function() m:add("", "/a") end, "non%-empty string")
      assert.has_error(function() m:add(42, "/a") end, "non%-empty string")
      assert.has_error(function() m:add("users-show", "/a") end, "invalid route id")
      assert.has_error(function() m:add("2users", "/a") end, "invalid route id")
      assert.has_error(function() m:add(".users", "/a") end, "invalid route id")
      assert.has_error(function() m:add("users.", "/a") end, "invalid route id")
      assert.has_error(function() m:add("users..show", "/a") end, "invalid route id")
    end)

    it("rejects a duplicate route id", function()
      local m = matcher.new()
      m:add("users.show", "/users/:id")
      assert.has_error(function() m:add("users.show", "/other/:id") end,
        "duplicate route id")
    end)

    --- The error must name BOTH colliding ids -- knowing only that
    --- "/about" is taken is not enough to go fix it.
    it("rejects a duplicate static path, naming both ids", function()
      local m = matcher.new()
      m:add("about", "/about")
      local ok, err = pcall(function() m:add("about_us", "/about") end)
      assert.falsy(ok)
      err = tostring(err)
      assert.truthy(err:find("duplicate static path", 1, true), err)
      assert.truthy(err:find("about_us", 1, true), "error must name the new id: " .. err)
      assert.truthy(err:find("\"about\"", 1, true), "error must name the existing id: " .. err)
    end)

    it("treats paths that normalize to the same static path as colliding", function()
      local m = matcher.new()
      m:add("about", "/about")
      assert.has_error(function() m:add("about2", "/about/") end, "duplicate static path")
    end)

    it("propagates pattern parse errors from add", function()
      local m = matcher.new()
      assert.has_error(function() m:add("bad", "no-slash") end, "must start with")
      assert.has_error(function() m:add("bad", "/:a/:a") end, "duplicate path param name")
    end)
  end)

  describe("matching", function()
    local function fixture()
      local m = matcher.new()
      m:add("home", "/")
      m:add("users.index", "/users")
      m:add("users.me", "/users/me")
      m:add("users.show", "/users/:id")
      m:add("users.tab", "/users/:id/:tab")
      m:add("files", "/files/:rest*")
      m:add("assets", "/assets/*")
      return m
    end

    it("matches the root", function()
      local r = fixture():match("/")
      assert.equal(r.route.id, "home")
      assert.same(r.params, {})
      assert.equal(r.path, "/")
    end)

    it("matches a static path", function()
      assert.equal(fixture():match("/users").route.id, "users.index")
    end)

    it("prefers a static path over a competing param pattern", function()
      assert.equal(fixture():match("/users/me").route.id, "users.me")
      assert.equal(fixture():match("/users/7").route.id, "users.show")
    end)

    it("captures a single-segment param", function()
      local r = fixture():match("/users/7")
      assert.same(r.params, { id = "7" })
    end)

    it("captures multiple params", function()
      local r = fixture():match("/users/7/settings")
      assert.equal(r.route.id, "users.tab")
      assert.same(r.params, { id = "7", tab = "settings" })
    end)

    it("percent-decodes captured param values", function()
      local r = fixture():match("/users/a%20b%2Fc")
      assert.same(r.params, { id = "a b/c" })
    end)

    --- A path segment's "+" is a literal plus, not a space. Decoding it
    --- as a space here would corrupt every id containing one.
    it("does not treat + in a path segment as a space", function()
      local r = fixture():match("/users/a+b")
      assert.same(r.params, { id = "a+b" })
    end)

    it("returns nil when nothing matches", function()
      assert.is_nil(fixture():match("/nope/at/all/here"))
      assert.is_nil(matcher.new():match("/"))
    end)

    it("normalizes the path before matching", function()
      local m = fixture()
      assert.equal(m:match("//users//me/").route.id, "users.me")
      assert.equal(m:match("/users/x/../me").route.id, "users.me")
    end)

    it("ignores a query string and fragment", function()
      local r = fixture():match("/users/7?tab=a#top")
      assert.equal(r.route.id, "users.show")
      assert.same(r.params, { id = "7" })
      assert.equal(r.path, "/users/7")
    end)

    it("reports extra unconsumed segments as a non-match", function()
      local m = matcher.new()
      m:add("users.show", "/users/:id")
      assert.is_nil(m:match("/users/7/extra"))
    end)

    it("reports too-few segments as a non-match", function()
      local m = matcher.new()
      m:add("users.tab", "/users/:id/:tab")
      assert.is_nil(m:match("/users/7"))
    end)
  end)

  describe("catch-all and wildcard", function()
    local function fixture()
      local m = matcher.new()
      m:add("files", "/files/:rest*")
      m:add("assets", "/assets/*")
      return m
    end

    it("joins the remaining segments with /", function()
      assert.same(fixture():match("/files/a/b/c").params, { rest = "a/b/c" })
    end)

    it("captures zero remaining segments as the empty string, not a non-match", function()
      local r = fixture():match("/files")
      assert.is_not_nil(r, "a catch-all must match its bare prefix")
      assert.same(r.params, { rest = "" })
    end)

    it("captures an anonymous wildcard under the key '*'", function()
      local r = fixture():match("/assets/img/logo.png")
      assert.equal(r.route.id, "assets")
      assert.same(r.params, { ["*"] = "img/logo.png" })
    end)

    --- Each remaining segment is decoded individually and only THEN
    --- joined, so an encoded %2F inside a segment stays data instead of
    --- silently becoming a structural separator.
    it("decodes remaining segments individually before joining", function()
      assert.same(fixture():match("/files/a%2Fb/c").params, { rest = "a/b/c" })
      assert.same(fixture():match("/files/a%20b/c").params, { rest = "a b/c" })
    end)
  end)

  describe("specificity ordering", function()
    it("prefers a literal over a param even when declared later", function()
      local m = matcher.new()
      m:add("show", "/users/:id/detail")
      m:add("me", "/users/me/detail")
      assert.equal(m:match("/users/me/detail").route.id, "me")
    end)

    it("prefers a param over a catch-all even when declared later", function()
      local m = matcher.new()
      m:add("rest", "/files/:rest*")
      m:add("one", "/files/:name")
      assert.equal(m:match("/files/a").route.id, "one")
      assert.equal(m:match("/files/a/b").route.id, "rest")
    end)

    it("orders dynamic routes by specificity regardless of add order", function()
      local function build(order)
        local m = matcher.new()
        local defs = {
          catch = "/x/:rest*",
          param = "/x/:name",
          two = "/x/:a/:b",
        }
        for _, id in ipairs(order) do m:add(id, defs[id]) end
        local ids = {}
        for i, r in ipairs(m:ordered_dynamic()) do ids[i] = r.id end
        return ids
      end
      local expected = { "two", "param", "catch" }
      assert.same(build({ "catch", "param", "two" }), expected)
      assert.same(build({ "two", "param", "catch" }), expected)
      assert.same(build({ "param", "catch", "two" }), expected)
    end)
  end)

  --[[
    THE DETERMINISM GROUP.

    Every route here has IDENTICAL specificity (two params), so
    `pattern.more_specific` reports a tie in both directions and the
    ONLY thing deciding the winner is the matcher's declaration-order
    tiebreaker. Enough routes are used that `table.sort` genuinely
    permutes the array when that tiebreaker is removed -- with two or
    three elements a broken comparator can still happen to leave them in
    place, which would make this test pass against a real defect.

    Verified as a real mutation check, not just a passing assertion:
    replacing the comparator's `return a.order < b.order` with
    `return false` makes these fail.
  --]]
  describe("declaration order is the only tiebreaker, and it is honoured", function()
    local IDS = { "r1", "r2", "r3", "r4", "r5", "r6", "r7", "r8", "r9", "r10" }

    local function build(order)
      local m = matcher.new()
      for _, id in ipairs(order) do
        -- Distinct patterns, identical scores {PARAM, PARAM}.
        m:add(id, "/:" .. id .. "_a/:" .. id .. "_b")
      end
      return m
    end

    local function reversed(t)
      local out = {}
      for i = #t, 1, -1 do out[#out + 1] = t[i] end
      return out
    end

    it("resolves an ambiguous path to the FIRST-declared route", function()
      assert.equal(build(IDS):match("/x/y").route.id, "r1")
    end)

    it("resolves to a different route when the SAME two routes are added in the opposite order", function()
      -- The competing routes are unchanged; only insertion order differs.
      -- If ordering leaked from table.sort or pairs, these two would not
      -- reliably disagree in this exact way.
      assert.equal(build(reversed(IDS)):match("/x/y").route.id, "r10")
    end)

    it("keeps the resolution order identical to the declaration order", function()
      local function ids_of(order)
        local out = {}
        for i, r in ipairs(build(order):ordered_dynamic()) do out[i] = r.id end
        return out
      end
      assert.same(ids_of(IDS), IDS)
      assert.same(ids_of(reversed(IDS)), reversed(IDS))
    end)

    it("produces byte-identical ordering across repeated builds of the same input", function()
      local function ids_of(order)
        local out = {}
        for i, r in ipairs(build(order):ordered_dynamic()) do out[i] = r.id end
        return table.concat(out, ",")
      end
      local first = ids_of(IDS)
      for _ = 1, 5 do
        assert.equal(ids_of(IDS), first, "ordering must not vary between runs")
      end
    end)

    it("sorts lazily but consistently, whether or not match ran first", function()
      local a = build(IDS)
      local b = build(IDS)
      b:match("/x/y")           -- forces the sort
      b:add("late", "/:p/:q")   -- marks dirty again
      a:add("late", "/:p/:q")
      local function ids_of(m)
        local out = {}
        for i, r in ipairs(m:ordered_dynamic()) do out[i] = r.id end
        return table.concat(out, ",")
      end
      assert.equal(ids_of(a), ids_of(b))
      assert.equal(ids_of(a), table.concat(IDS, ",") .. ",late")
    end)
  end)

end)
