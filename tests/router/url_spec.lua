--[[
  Tests for hydronium_router.url -- percent-encoding, href splitting,
  query parsing/building, and path normalization.

  The `+` cases below are the ones that matter most: `+` is a space in a
  query string and a literal plus sign in a path, and getting that
  backwards corrupts data silently.
--]]

local h = require("tests.runner")
local describe, it, assert = h.describe, h.it, h.assert

local url = require("hydronium_router.url")

describe("Router: url", function()

  describe("encode / decode", function()
    it("leaves the RFC 3986 unreserved set alone", function()
      assert.equal(url.encode("aZ09-_.~"), "aZ09-_.~")
    end)

    it("percent-encodes a space as %20, never as +", function()
      assert.equal(url.encode("a b"), "a%20b")
    end)

    it("encodes reserved and non-ASCII bytes", function()
      assert.equal(url.encode("a/b"), "a%2Fb")
      assert.equal(url.encode("?&=#"), "%3F%26%3D%23")
      assert.equal(url.encode("é"), "%C3%A9")
    end)

    it("round-trips through decode", function()
      local s = "a b/c?d&e=f#g é+h"
      assert.equal(url.decode(url.encode(s)), s)
    end)

    it("decodes uppercase and lowercase hex", function()
      assert.equal(url.decode("%C3%A9"), "é")
      assert.equal(url.decode("%c3%a9"), "é")
    end)

    --- THE TRAP: a path segment "a+b" is a literal plus. Only a query
    --- component may read it as a space.
    it("treats + as a literal plus by default (path-safe)", function()
      assert.equal(url.decode("a+b"), "a+b")
    end)

    it("treats + as a space only when explicitly told to", function()
      assert.equal(url.decode("a+b", true), "a b")
    end)

    it("leaves an un-encoded percent sign alone rather than erroring", function()
      assert.equal(url.decode("100%"), "100%")
    end)
  end)

  describe("split", function()
    it("splits path, query, and hash", function()
      local p, q, f = url.split("/a/b?x=1&y=2#top")
      assert.equal(p, "/a/b")
      assert.equal(q, "x=1&y=2")
      assert.equal(f, "top")
    end)

    it("returns nil for absent query and hash", function()
      local p, q, f = url.split("/a/b")
      assert.equal(p, "/a/b")
      assert.is_nil(q)
      assert.is_nil(f)
    end)

    it("returns nil query when only a hash is present", function()
      local p, q, f = url.split("/a#top")
      assert.equal(p, "/a")
      assert.is_nil(q)
      assert.equal(f, "top")
    end)

    --- Per RFC 3986 the fragment is last, so a "?" AFTER a "#" belongs
    --- to the fragment and must not be read as a query delimiter.
    it("strips the fragment first, so a ? inside it stays in the fragment", function()
      local p, q, f = url.split("/a#frag?notquery")
      assert.equal(p, "/a")
      assert.is_nil(q)
      assert.equal(f, "frag?notquery")
    end)

    it("handles an empty query and an empty hash", function()
      local p, q, f = url.split("/a?#")
      assert.equal(p, "/a")
      assert.equal(q, "")
      assert.equal(f, "")
    end)
  end)

  describe("parse_query", function()
    it("returns an empty table for nil and empty input", function()
      assert.same(url.parse_query(nil), {})
      assert.same(url.parse_query(""), {})
    end)

    it("parses simple pairs", function()
      assert.same(url.parse_query("a=1&b=2"), { a = "1", b = "2" })
    end)

    it("gives a bare key the empty string", function()
      assert.same(url.parse_query("flag"), { flag = "" })
      assert.same(url.parse_query("flag="), { flag = "" })
    end)

    it("collects a repeated key into an array in first-seen order", function()
      assert.same(url.parse_query("t=a&t=b&t=c"), { t = { "a", "b", "c" } })
    end)

    it("percent-decodes keys and values", function()
      assert.same(url.parse_query("a%20b=c%2Fd"), { ["a b"] = "c/d" })
    end)

    it("decodes + as a space, because this IS a query string", function()
      assert.same(url.parse_query("q=hello+world"), { q = "hello world" })
    end)

    it("keeps a value containing = intact after the first =", function()
      assert.same(url.parse_query("eq=a=b"), { eq = "a=b" })
    end)
  end)

  describe("build_query", function()
    it("returns an empty string for nil and empty input", function()
      assert.equal(url.build_query(nil), "")
      assert.equal(url.build_query({}), "")
    end)

    --- Sorted keys are what make this testable at all: Lua's `pairs`
    --- order is unspecified, so an unsorted builder would emit a
    --- different string for the same input across runs.
    it("emits keys in sorted order, deterministically", function()
      local t = { zeta = "1", alpha = "2", mid = "3" }
      assert.equal(url.build_query(t), "alpha=2&mid=3&zeta=1")
      -- Same table, built again: byte-identical.
      assert.equal(url.build_query(t), url.build_query(t))
    end)

    it("encodes keys and values", function()
      assert.equal(url.build_query({ ["a b"] = "c/d" }), "a%20b=c%2Fd")
    end)

    it("emits one pair per element for an array value, in array order", function()
      assert.equal(url.build_query({ t = { "b", "a" } }), "t=b&t=a")
    end)

    it("tostrings numbers and booleans", function()
      assert.equal(url.build_query({ n = 42, ok = true }), "n=42&ok=true")
    end)

    it("round-trips through parse_query", function()
      local original = { a = "x y", b = "1", c = { "p", "q" } }
      assert.same(url.parse_query(url.build_query(original)), original)
    end)

    it("rejects a non-table argument", function()
      assert.has_error(function() url.build_query("a=1") end, "expected a table")
    end)
  end)

  describe("normalize_path", function()
    it("returns / for nil and empty input", function()
      assert.equal(url.normalize_path(nil), "/")
      assert.equal(url.normalize_path(""), "/")
      assert.equal(url.normalize_path("/"), "/")
    end)

    it("adds a leading slash", function()
      assert.equal(url.normalize_path("a/b"), "/a/b")
    end)

    it("collapses duplicate slashes", function()
      assert.equal(url.normalize_path("//a///b//"), "/a/b")
    end)

    it("drops a trailing slash but keeps root as /", function()
      assert.equal(url.normalize_path("/a/b/"), "/a/b")
      assert.equal(url.normalize_path("///"), "/")
    end)

    it("drops . segments", function()
      assert.equal(url.normalize_path("/a/./b"), "/a/b")
      assert.equal(url.normalize_path("/./a"), "/a")
    end)

    --- Resolving `..` for real, not stripping it: "/a/../b" is "/b",
    --- and a naive strip would produce "/a/b".
    it("resolves .. by popping the previous segment", function()
      assert.equal(url.normalize_path("/a/../b"), "/b")
      assert.equal(url.normalize_path("/a/b/../../c"), "/c")
      assert.equal(url.normalize_path("/a/b/.."), "/a")
    end)

    it("never escapes above the root", function()
      assert.equal(url.normalize_path("/../a"), "/a")
      assert.equal(url.normalize_path("/../../a/../b"), "/b")
      assert.equal(url.normalize_path("/.."), "/")
    end)

    it("leaves percent-encoding untouched", function()
      assert.equal(url.normalize_path("/a%20b/c"), "/a%20b/c")
    end)
  end)

  describe("path_segments", function()
    it("splits on runs of slashes", function()
      assert.same(url.path_segments("/a/b/c"), { "a", "b", "c" })
      assert.same(url.path_segments("//a//b"), { "a", "b" })
    end)

    it("returns an empty array for the root", function()
      assert.same(url.path_segments("/"), {})
    end)
  end)

end)
