--[[
  hydronium_dom.dev.watch -- per-module change identity (roadmap M2).

  Covers the pure, testable half of the M2 protocol addition: reading a
  fingerprint back apart into its per-file stat entries, and naming
  exactly which watched paths moved between two fingerprints. The SSE
  half (`serve_sse`) is not covered here -- it depends on Meteorite's
  per-request `stream_begin`/`stream_write` globals and a real HTTP
  client, and is verified end to end by the Playwright HMR proof
  instead, which is where a transport bug would actually show up.

  Fingerprint lines are the real output shape of the `stat` commands
  `M.fingerprint` runs: "<mtime> <size> <name>", "|"-joined and sorted.
--]]

local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert

local watch = require("hydronium_dom.dev.watch")

describe("hydronium_dom.dev.watch -- per-file change identity", function()
  describe("parse_fingerprint", function()
    it("splits a real multi-file fingerprint into per-path stamps", function()
      local fp = "1757000000.0 100 views/App.luax|1757000001.0 200 views/Counter.luax"
      assert.same(watch.parse_fingerprint(fp), {
        ["views/App.luax"] = "1757000000.0 100",
        ["views/Counter.luax"] = "1757000001.0 200",
      })
    end)

    it("keeps a path containing spaces intact", function()
      -- The name is everything after the second field, not the third
      -- token -- a real path may contain spaces and must not be cut.
      local parsed = watch.parse_fingerprint("1757000000.0 100 views/My Counter.luax")
      assert.same(parsed, { ["views/My Counter.luax"] = "1757000000.0 100" })
    end)

    it("returns an empty table for nil and for the empty string", function()
      assert.same(watch.parse_fingerprint(nil), {})
      assert.same(watch.parse_fingerprint(""), {})
    end)
  end)

  describe("changed_files", function()
    local base = "1757000000.0 100 views/App.luax|1757000000.0 200 views/Counter.luax"

    it("names only the file whose stat line moved", function()
      local next_fp = "1757000000.0 100 views/App.luax|1757000009.0 205 views/Counter.luax"
      assert.same(watch.changed_files(base, next_fp), { "views/Counter.luax" })
    end)

    it("returns nothing when the whole set is unchanged", function()
      assert.same(watch.changed_files(base, base), {})
    end)

    it("detects a size-only change (same mtime, edited content)", function()
      local next_fp = "1757000000.0 100 views/App.luax|1757000000.0 999 views/Counter.luax"
      assert.same(watch.changed_files(base, next_fp), { "views/Counter.luax" })
    end)

    it("reports a created file, absent from the previous fingerprint", function()
      -- `stat` on a missing file prints nothing, so a not-yet-existing
      -- watched file simply has no line -- creation looks like an entry
      -- appearing, not like a modification.
      local prev = "1757000000.0 100 views/App.luax"
      assert.same(watch.changed_files(prev, base), { "views/Counter.luax" })
    end)

    it("reports a deleted file, absent from the new fingerprint", function()
      local next_fp = "1757000000.0 100 views/App.luax"
      assert.same(watch.changed_files(base, next_fp), { "views/Counter.luax" })
    end)

    it("reports several changed files in sorted order", function()
      local next_fp = "1757000005.0 101 views/App.luax|1757000005.0 201 views/Counter.luax"
      assert.same(watch.changed_files(base, next_fp), { "views/App.luax", "views/Counter.luax" })
    end)

    it("treats an empty or missing previous fingerprint as everything changed", function()
      assert.same(watch.changed_files("", base), { "views/App.luax", "views/Counter.luax" })
      assert.same(watch.changed_files(nil, base), { "views/App.luax", "views/Counter.luax" })
    end)
  end)

  describe("fingerprint still behaves as the whole-set digest consumers rely on", function()
    it("is stable, sorted, and moves when a real watched file changes", function()
      local path = os.tmpname()
      -- NOTE: `assert` here is the runner's assertion TABLE, not Lua's
      -- global assert function, so file handles are checked explicitly.
      local f = io.open(path, "w")
      assert.truthy(f, "could not open temp file for writing")
      f:write("one")
      f:close()

      local first = watch.fingerprint({ path }, 0, false)
      assert.truthy(first ~= "" and first ~= nil)
      assert.equal(watch.fingerprint({ path }, 0, false), first)

      -- Rewritten with a different LENGTH, so the fingerprint moves via
      -- the size field even if the filesystem's mtime resolution has
      -- not ticked between the two writes.
      local g = io.open(path, "w")
      assert.truthy(g, "could not reopen temp file for writing")
      g:write("one-two-three")
      g:close()

      local second = watch.fingerprint({ path }, 0, false)
      assert.not_equal(second, first)
      assert.same(watch.changed_files(first, second), { path })

      os.remove(path)
    end)
  end)
end)
