--[[
  hydronium_dom.dev.watch -- per-module change identity (roadmap M2).

  Covers the pure, testable half of the M2 protocol addition: reading a
  legacy fingerprint parsing, compact revisions, and naming exactly
  which watched paths moved between two snapshots. The SSE
  tests replace Meteorite's per-request stream globals with narrow fakes
  so abandoned-connection behavior remains deterministic here.

  Legacy fingerprint lines have the shape "<hashes> <size> <name>".
--]]

local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert

local watch = require("hydronium_dom.dev.watch")

local function with_fake_streams(write, fn)
  local old_begin, old_write, old_end = stream_begin, stream_write, stream_end
  stream_begin = function() end
  stream_write = write
  stream_end = function() end
  local ok, err = pcall(fn)
  stream_begin, stream_write, stream_end = old_begin, old_write, old_end
  if not ok then error(err, 0) end
end

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

    it("names only the file whose content stamp moved", function()
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
      -- A missing watched file has no entry, so creation looks like an
      -- entry appearing rather than a modification.
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

      local first = watch.snapshot({ path })
      assert.equal(#first.revision, 16)
      assert.equal(watch.fingerprint({ path }), first.revision)

      -- Same length and potentially the same filesystem timestamp: the
      -- content hashes, not metadata, must move the fingerprint.
      local g = io.open(path, "w")
      assert.truthy(g, "could not reopen temp file for writing")
      g:write("two")
      g:close()

      local second = watch.snapshot({ path })
      assert.not_equal(second.revision, first.revision)
      assert.same(watch.changed_files(first.entries, second.entries), { path })

      os.remove(path)
    end)
  end)

  describe("compact revisions", function()
    it("stays 16 hex bytes for 200 files and ignores file-list order", function()
      local files = {}
      local prefix = os.tmpname()
      for index = 1, 200 do
        files[index] = string.format("%s-%03d.lua", prefix, index)
        local file = io.open(files[index], "w")
        assert.truthy(file)
        file:write("return ", index, "\n")
        file:close()
      end
      local first_snapshot = watch.snapshot(files)
      local first = first_snapshot.revision
      assert.equal(#first, 16)
      assert.truthy(first:match("^[0-9a-f]+$"))
      local reversed = {}
      for index = #files, 1, -1 do reversed[#reversed + 1] = files[index] end
      assert.equal(watch.fingerprint(reversed), first)
      local edited = io.open(files[200], "w")
      assert.truthy(edited)
      edited:write("return 999\n")
      edited:close()
      local next_snapshot = watch.snapshot(files)
      assert.equal(#next_snapshot.revision, 16)
      assert.not_equal(next_snapshot.revision, first)
      assert.same(watch.changed_files(first_snapshot.entries, next_snapshot.entries), { files[200] })
      os.remove(files[200])
      local deleted_snapshot = watch.snapshot(files)
      assert.not_equal(deleted_snapshot.revision, next_snapshot.revision)
      assert.same(watch.changed_files(next_snapshot.entries, deleted_snapshot.entries), { files[200] })
      for _, path in ipairs(files) do os.remove(path) end
      os.remove(prefix)
    end)
  end)

  describe("read_snapshot", function()
    it("returns a source value only when its watched revision remains stable", function()
      local old_fingerprint = watch.fingerprint
      local calls = 0
      watch.fingerprint = function()
        calls = calls + 1
        return "revision-a"
      end
      local value, revision, reason = watch.read_snapshot({ "views/App.luax" }, "revision-a", function()
        return "compiled source"
      end)
      watch.fingerprint = old_fingerprint
      assert.equal(value, "compiled source")
      assert.equal(revision, "revision-a")
      assert.falsy(reason)
      assert.equal(calls, 2)
    end)

    it("rejects a request that names an obsolete event revision before reading", function()
      local old_fingerprint = watch.fingerprint
      watch.fingerprint = function() return "revision-b" end
      local read = false
      local value, revision, reason = watch.read_snapshot({ "views/App.luax" }, "revision-a", function()
        read = true
        return "must not be read"
      end)
      watch.fingerprint = old_fingerprint
      assert.falsy(value)
      assert.equal(revision, "revision-b")
      assert.equal(reason, "stale")
      assert.falsy(read)
    end)

    it("rejects a source read when a watched file changes during it", function()
      local old_fingerprint = watch.fingerprint
      local calls = 0
      watch.fingerprint = function()
        calls = calls + 1
        return calls == 1 and "revision-a" or "revision-b"
      end
      local value, revision, reason = watch.read_snapshot({ "views/App.luax" }, "revision-a", function()
        return "mixed source"
      end)
      watch.fingerprint = old_fingerprint
      assert.falsy(value)
      assert.equal(revision, "revision-b")
      assert.equal(reason, "stale")
    end)
  end)
end)

describe("hydronium_dom.dev.watch -- abandoned connections", function()
  it("reads protocol controls from Meteorite's callable query table", function()
    local old_snapshot = watch.snapshot
    watch.snapshot = function() return { revision = "current", entries = { ["views/App.luax"] = "stamp" } } end
    local frames = {}
    local query = setmetatable({}, {
      __call = function(_, key)
        if key == "budget" then return "0" end
        if key == "since" then return "previous" end
      end,
    })
    local ok, err = pcall(function()
      with_fake_streams(function(chunk)
        frames[#frames + 1] = chunk
      end, function()
        watch.serve_sse({ header = function() end, query = query }, { "unused" })
      end)
    end)
    watch.snapshot = old_snapshot
    assert.truthy(ok, err)
    local output = table.concat(frames)
    assert.truthy(output:find("event: snapshot", 1, true))
    assert.truthy(output:find("event: reload", 1, true))
    assert.falsy(output:find("event: ping", 1, true))
    assert.falsy(output:find("event: bye", 1, true))
  end)

  it("sends changed paths and a fresh snapshot before an in-session reload", function()
    local old_snapshot = watch.snapshot
    local calls = 0
    watch.snapshot = function()
      calls = calls + 1
      if calls == 1 then return { revision = "old", entries = { ["views/App.luax"] = "one" } } end
      return { revision = "new", entries = { ["views/App.luax"] = "two" } }
    end
    local frames = {}
    local ok, err = pcall(function()
      with_fake_streams(function(chunk)
        frames[#frames + 1] = chunk
      end, function()
        watch.serve_sse({ header = function() end, query = function() end }, { "unused" }, {
          poll_interval = 0.5,
          budget = 0.5,
          sleep = function() end,
        })
      end)
    end)
    watch.snapshot = old_snapshot
    assert.truthy(ok, err)
    local output = table.concat(frames)
    local changed = output:find("event: changed\ndata: views/App.luax", 1, true)
    local snapshot = output:find('event: snapshot\ndata: {"views/App.luax":"two"}', 1, true)
    local reload = output:find("event: reload\ndata: new", 1, true)
    assert.truthy(changed and snapshot and reload and changed < snapshot and snapshot < reload)
  end)

  it("treats a failed heartbeat write as a normal disconnect", function()
    local old_snapshot = watch.snapshot
    watch.snapshot = function() return { revision = "same", entries = {} } end
    local writes = 0
    local ok, err = pcall(function()
      with_fake_streams(function()
        writes = writes + 1
        if writes == 3 then error("WriteFailed", 0) end
      end, function()
        watch.serve_sse({ header = function() end, query = function() end }, { "unused" }, {
          poll_interval = 0.5,
          budget = 5,
          sleep = function() end,
        })
      end)
    end)
    watch.snapshot = old_snapshot
    assert.truthy(ok, err)
    assert.equal(writes, 3, "retry, snapshot, then hello")
  end)

  it("heartbeats every poll by default", function()
    local old_snapshot = watch.snapshot
    watch.snapshot = function() return { revision = "same", entries = {} } end
    local frames = {}
    local ok, err = pcall(function()
      with_fake_streams(function(chunk)
        frames[#frames + 1] = chunk
      end, function()
        watch.serve_sse({ header = function() end, query = function() end }, { "unused" }, {
          poll_interval = 0.5,
          budget = 1,
          sleep = function() end,
        })
      end)
    end)
    watch.snapshot = old_snapshot
    assert.truthy(ok, err)
    local pings = 0
    for _, frame in ipairs(frames) do
      if frame:find("event: ping", 1, true) then pings = pings + 1 end
    end
    assert.equal(pings, 2)
  end)
end)
