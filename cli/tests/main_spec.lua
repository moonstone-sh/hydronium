--[[
  hydronium-cli main -- the flag grammar, the argv actually handed to the
  spawned `meteorite dev`, and reading the durable log back.

  Requiring `main` is safe from a spec: its bottom-of-file self-exec guard
  only runs when `arg[0]` itself ends in `main.lua` (here it is the test
  runner), so this loads the module without starting a dev server. Nothing
  below reaches `M.dev`, which is the one function that needs a terminal,
  a child process and hydronium_ink's native Yoga binding.
--]]

local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert

-- The runner REPLACES the global `assert` with its own assertion table
-- (tests/runner.lua's `_G.assert = M.assert`), so neither `assert` nor
-- `_G.assert` is callable here. This is the "must not be nil, and give me
-- the value" helper the specs below need in its place.
local function must(value, message)
  if not value then
    error(message or "expected a value, got nil/false", 2)
  end
  return value
end

local main = require("main")
local dev_log = require("dev_log")
local event_model = require("event_model")

local function temp_path(name)
  return os.tmpname() .. "-" .. name
end

local function write_file(path, text)
  local file = must(io.open(path, "w"))
  file:write(text)
  file:close()
end

describe("hydronium-cli main -- parse_args", function()
  it("defaults every display flag to off", function()
    local parsed = must(main.parse_args({ "dev" }))
    assert.equal(parsed.command, "dev")
    assert.falsy(parsed.verbose)
    assert.falsy(parsed.show_ips)
    assert.falsy(parsed.fullscreen)
    assert.is_nil(parsed.meteorite_args)
  end)

  it("parses --fullscreen independently of the other display flags", function()
    local parsed = must(main.parse_args({ "dev", "--fullscreen" }))
    assert.truthy(parsed.fullscreen)
    assert.falsy(parsed.verbose, "--fullscreen must not imply --verbose")
    assert.falsy(parsed.show_ips, "--fullscreen must not imply --show-ips")

    local all = must(main.parse_args({ "dev", "--verbose", "--show-ips", "--fullscreen" }))
    assert.truthy(all.verbose and all.show_ips and all.fullscreen)
  end)

  it("accepts --meteorite-args as one separate word or with an equals sign", function()
    local spaced = must(main.parse_args({ "dev", "--meteorite-args", "--mode hybrid_dev --backend fast_http" }))
    assert.equal(spaced.meteorite_args, "--mode hybrid_dev --backend fast_http")

    local equals = must(main.parse_args({ "dev", "--meteorite-args=--mode static_dev" }))
    assert.equal(equals.meteorite_args, "--mode static_dev")
  end)

  it("does not mistake the words of --meteorite-args for its own flags", function()
    -- The real hazard of a value-taking option in a hand-rolled parser:
    -- the value here contains a `--verbose` that belongs to meteorite.
    local parsed = must(main.parse_args({ "dev", "--meteorite-args", "--mode hybrid_dev --verbose", "--show-ips" }))
    assert.equal(parsed.meteorite_args, "--mode hybrid_dev --verbose")
    assert.truthy(parsed.show_ips, "flags after the option's value must still parse")
    assert.falsy(parsed.verbose, "a --verbose inside the value is meteorite's, not this CLI's")
  end)

  it("errors rather than guessing when --meteorite-args has no value", function()
    local parsed, err = main.parse_args({ "dev", "--meteorite-args" })
    assert.is_nil(parsed)
    assert.truthy(err:find("requires a value", 1, true), err)
  end)

  it("still rejects an unknown flag", function()
    local parsed, err = main.parse_args({ "dev", "--inspect" })
    assert.is_nil(parsed)
    assert.truthy(err:find("unknown argument", 1, true), err)
  end)

  it("documents the fullscreen flag and its keys in the usage text", function()
    assert.truthy(main.USAGE:find("--fullscreen", 1, true))
    assert.truthy(main.USAGE:find("--meteorite-args", 1, true))
    assert.truthy(main.USAGE:find("Toggle the fullscreen", 1, true), "the toggle key must be documented")
  end)
end)

describe("hydronium-cli main -- meteorite_argv", function()
  it("spawns a bare `meteorite dev` when nothing was passed", function()
    assert.same(main.meteorite_argv({ command = "dev" }, nil), { "meteorite", "dev" })
  end)

  it("appends the flag's words in order, unquoted and unsplit", function()
    local argv = main.meteorite_argv(
      { meteorite_args = "--mode hybrid_dev --backend fast_http --lua-root .moonstone/env/libexec/luajit" },
      nil
    )
    assert.same(argv, {
      "meteorite", "dev",
      "--mode", "hybrid_dev",
      "--backend", "fast_http",
      "--lua-root", ".moonstone/env/libexec/luajit",
    })
  end)

  it("puts the environment's words AFTER the flag's, so a one-off override wins", function()
    local argv = main.meteorite_argv({ meteorite_args = "--mode hybrid_dev" }, "--mode static_dev")
    assert.same(argv, { "meteorite", "dev", "--mode", "hybrid_dev", "--mode", "static_dev" })
  end)

  it("still honours the environment variable on its own (the pre-flag escape hatch)", function()
    local argv = main.meteorite_argv({ command = "dev" }, "--mode hybrid_dev --backend fast_http")
    assert.same(argv, { "meteorite", "dev", "--mode", "hybrid_dev", "--backend", "fast_http" })
  end)

  it("collapses runs of whitespace rather than emitting empty arguments", function()
    local argv = main.meteorite_argv({ meteorite_args = "  --mode   hybrid_dev \t--backend fast_http " }, nil)
    assert.same(argv, { "meteorite", "dev", "--mode", "hybrid_dev", "--backend", "fast_http" })
  end)
end)

describe("hydronium-cli dev_log -- read_events", function()
  it("reads a durable log back, keeping only what the filter accepts", function()
    local path = temp_path("dev.log")
    write_file(path, table.concat({
      '{"v":1,"ts":1000,"source":"cli","kind":"startup","command":"dev"}',
      '{"v":1,"ts":1100,"source":"server","kind":"request","method":"GET","path":"/a","status":200,"duration_ms":5}',
      '{"v":1,"ts":1200,"source":"supervisor","kind":"reload","ok":true}',
      '{"v":1,"ts":1300,"source":"server","kind":"request","method":"POST","path":"/b","status":500,"duration_ms":9}',
      "",
    }, "\n"))

    local events, skipped = dev_log.read_events(path, { filter = event_model.is_request })
    assert.equal(#events, 2)
    assert.equal(events[1].path, "/a")
    assert.equal(events[2].method, "POST")
    assert.equal(skipped, 0)
    os.remove(path)
  end)

  it("keeps only the newest `limit` events, so a long-lived log cannot grow into memory unbounded", function()
    local path = temp_path("dev-big.log")
    local lines = {}
    for i = 1, 50 do
      lines[i] = '{"v":1,"ts":' .. (1000 + i)
        .. ',"source":"server","kind":"request","method":"GET","path":"/p' .. i
        .. '","status":200,"duration_ms":1}'
    end
    write_file(path, table.concat(lines, "\n") .. "\n")

    local events = dev_log.read_events(path, { filter = event_model.is_request, limit = 10 })
    assert.equal(#events, 10)
    assert.equal(events[1].path, "/p41", "the oldest kept row must be the 41st of 50")
    assert.equal(events[10].path, "/p50", "the newest row must always be kept")
    os.remove(path)
  end)

  it("counts garbage lines instead of raising on them", function()
    local path = temp_path("dev-garbage.log")
    write_file(path, table.concat({
      "not json at all",
      '{"v":1,"ts":1100,"source":"server","kind":"request","method":"GET","path":"/a","status":200,"duration_ms":5}',
      '{"v":2,"ts":1200,"source":"server","kind":"request"}',
      "",
      "   ",
      "",
    }, "\n"))

    local events, skipped = dev_log.read_events(path)
    assert.equal(#events, 1)
    assert.equal(skipped, 2, "the unparseable line and the future schema version, not the blank ones")
    os.remove(path)
  end)

  it("treats a missing log as empty, not as an error", function()
    local events, skipped = dev_log.read_events("/nonexistent/hydronium/dev.log")
    assert.same(events, {})
    assert.equal(skipped, 0)
  end)
end)
