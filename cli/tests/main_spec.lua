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
  it("parses the turnkey Lab command and validates its port", function()
    local parsed = must(main.parse_args({ "lab", "--port", "6200", "--no-open" }))
    assert.equal(parsed.command, "lab")
    assert.equal(parsed.port, 6200)
    assert.truthy(parsed.no_open)
    assert.truthy(must(main.parse_args({ "lab", "init" })).init)
    local invalid, err = main.parse_args({ "lab", "--port", "0" })
    assert.is_nil(invalid)
    assert.truthy(err:find("1 to 65535", 1, true))
  end)

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

describe("hydronium-cli Lab compatibility alias", function()
  it("delegates launch flags to the standalone Lab CLI", function()
    local command = main.lab_command({ host = "0.0.0.0", port = 6200, config = "config/lab.lua", adapter = "meteorite", no_open = true })
    assert.truthy(command:find("hydronium%-lab dev"))
    assert.truthy(command:find("%-%-host '0%.0%.0%.0'"))
    assert.truthy(command:find("%-%-port 6200"))
    assert.truthy(command:find("%-%-config 'config/lab%.lua'"))
    assert.truthy(command:find("%-%-adapter 'meteorite'"))
    assert.truthy(command:find("%-%-no%-open"))
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

describe("hydronium-cli main -- --vite/--ballad parsing", function()
  it("defaults --vite and --ballad to off", function()
    local parsed = must(main.parse_args({ "dev" }))
    assert.falsy(parsed.vite)
    assert.is_nil(parsed.vite_args)
    assert.is_nil(parsed.vite_dir)
    assert.falsy(parsed.ballad)
    assert.is_nil(parsed.ballad_args)
  end)

  it("--vite-args and --vite-dir imply --vite", function()
    local viaArgs = must(main.parse_args({ "dev", "--vite-args", "--port 5174" }))
    assert.truthy(viaArgs.vite)
    assert.equal(viaArgs.vite_args, "--port 5174")

    local viaEquals = must(main.parse_args({ "dev", "--vite-args=--port 5174" }))
    assert.truthy(viaEquals.vite)
    assert.equal(viaEquals.vite_args, "--port 5174")

    local viaDir = must(main.parse_args({ "dev", "--vite-dir=apps/web" }))
    assert.equal(viaDir.vite_dir, "apps/web")
  end)

  it("--ballad-args implies --ballad", function()
    local parsed = must(main.parse_args({ "dev", "--ballad-args=partiture.lua --jobs 4" }))
    assert.truthy(parsed.ballad)
    assert.equal(parsed.ballad_args, "partiture.lua --jobs 4")
  end)

  it("errors rather than guessing when a value-taking flag has no value", function()
    local noVite, viteErr = main.parse_args({ "dev", "--vite-args" })
    assert.is_nil(noVite)
    assert.truthy(viteErr:find("requires a value", 1, true), viteErr)

    local noDir, dirErr = main.parse_args({ "dev", "--vite-dir" })
    assert.is_nil(noDir)
    assert.truthy(dirErr:find("requires a value", 1, true), dirErr)

    local noBallad, balladErr = main.parse_args({ "dev", "--ballad-args" })
    assert.is_nil(noBallad)
    assert.truthy(balladErr:find("requires a value", 1, true), balladErr)
  end)
end)

describe("hydronium-cli main -- vite_argv / dual_dev_specs / dual_dev_argv", function()
  it("vite_argv is empty by default and splits --vite-args like meteorite_argv does", function()
    assert.same(main.vite_argv({}), {})
    assert.same(main.vite_argv({ vite_args = "  --port   5174 \t--strictPort " }), { "--port", "5174", "--strictPort" })
  end)

  it("dual_dev_specs pairs meteorite's own argv with an npx-run vite, defaulting cwd to '.'", function()
    local specs = main.dual_dev_specs(
      { "meteorite", "dev", "--mode", "hybrid_dev" },
      { vite_args = "--port 5174" }
    )
    assert.same(specs, {
      { name = "meteorite", command = "meteorite", args = { "dev", "--mode", "hybrid_dev" } },
      { name = "vite", command = "npx", args = { "vite", "--port", "5174" }, cwd = "." },
    })
  end)

  it("dual_dev_specs honours --vite-dir as the vite process's cwd", function()
    local specs = main.dual_dev_specs({ "meteorite", "dev" }, { vite_dir = "apps/web" })
    assert.equal(specs[2].cwd, "apps/web")
  end)

  it("dual_dev_argv builds a node invocation of the dual-dev wrapper with the specs JSON-encoded", function()
    local seen_value
    local function fake_encode(value)
      seen_value = value
      return "ENCODED"
    end
    local argv = main.dual_dev_argv("/repo", { "meteorite", "dev" }, { vite_dir = "." }, fake_encode)
    assert.same(argv, { "node", "/repo/js/packages/vite/bin/dual-dev.mjs", "--specs", "ENCODED" })
    assert.equal(seen_value[1].name, "meteorite")
    assert.equal(seen_value[2].name, "vite")
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

describe("hydronium-cli main -- parse_build_args", function()
  it("defaults to the Ink view, verify on, no vite, partiture.lua", function()
    local parsed = must(main.parse_args({ "build" }))
    assert.equal(parsed.command, "build")
    assert.is_nil(parsed.file)
    assert.equal(parsed.output, "ink")
    assert.truthy(parsed.verify)
    assert.falsy(parsed.vite)
  end)

  it("--plain and --ndjson select the headless output modes", function()
    assert.equal(must(main.parse_args({ "build", "--plain" })).output, "plain")
    assert.equal(must(main.parse_args({ "build", "--ndjson" })).output, "ndjson")
  end)

  it("rejects --plain and --ndjson together", function()
    local parsed, err = main.parse_args({ "build", "--plain", "--ndjson" })
    assert.is_nil(parsed)
    assert.truthy(err:find("mutually exclusive", 1, true))
    parsed, err = main.parse_args({ "build", "--ndjson", "--plain" })
    assert.is_nil(parsed)
    assert.truthy(err:find("mutually exclusive", 1, true))
  end)

  it("--no-verify turns verification off", function()
    assert.falsy(must(main.parse_args({ "build", "--no-verify" })).verify)
  end)

  it("--file (both spellings) overrides the default partiture path", function()
    assert.equal(must(main.parse_args({ "build", "--file", "other.lua" })).file, "other.lua")
    assert.equal(must(main.parse_args({ "build", "--file=other.lua" })).file, "other.lua")
  end)

  it("--vite-args implies --vite; --vite-dir only sets the directory (same asymmetry as `dev`'s own flags)", function()
    local parsed = must(main.parse_args({ "build", "--vite-args", "--mode production" }))
    assert.truthy(parsed.vite)
    assert.equal(parsed.vite_args, "--mode production")

    parsed = must(main.parse_args({ "build", "--vite-dir", "web" }))
    assert.falsy(parsed.vite)
    assert.equal(parsed.vite_dir, "web")
  end)

  it("errors rather than guessing when a value-taking flag has no value", function()
    for _, flag in ipairs({ "--file", "--vite-args", "--vite-dir" }) do
      local parsed, err = main.parse_args({ "build", flag })
      assert.is_nil(parsed, flag .. " should require a value")
      assert.truthy(err:find("requires a value", 1, true))
    end
  end)

  it("still rejects an unknown flag", function()
    local parsed, err = main.parse_args({ "build", "--bogus" })
    assert.is_nil(parsed)
    assert.truthy(err:find("unknown argument", 1, true))
  end)

  it("routes -h/--help to the build-specific usage topic", function()
    local parsed = must(main.parse_args({ "build", "--help" }))
    assert.equal(parsed.command, "help")
    assert.equal(parsed.topic, "build")
  end)

  it("documents every exit code hydronium build can return", function()
    for _, code in ipairs({ "0", "1", "2", "3", "4", "5" }) do
      assert.truthy(main.BUILD_USAGE:find("\n  " .. code .. "  ", 1, true), "missing exit code " .. code)
    end
  end)
end)

describe("hydronium-cli dev -- HMR/dev-endpoint display filtering", function()

  local function request(path)
    return { kind = "request", method = "GET", path = path, status = 200, ts = 1 }
  end

  it("classifies every hydronium dev endpoint as dev traffic", function()
    assert.equal(event_model.is_dev_endpoint(request("/__hydronium/watch")), true)
    assert.equal(event_model.is_dev_endpoint(request("/__hydronium/hmr")), true)
    assert.equal(event_model.is_dev_endpoint(request("/__hydronium/dev/module/app")), true)
    assert.equal(event_model.is_dev_endpoint(request("/__hydronium/client")), true)
    assert.equal(event_model.is_dev_endpoint(request("/__hydronium/client_manifest")), true)
  end)

  it("leaves real application traffic alone", function()
    assert.equal(event_model.is_dev_endpoint(request("/")), false)
    assert.equal(event_model.is_dev_endpoint(request("/api/users")), false)
    -- A path that merely mentions the prefix as a segment of something the
    -- app serves itself must not be swallowed.
    assert.equal(event_model.is_dev_endpoint(request("/docs/__hydronium-guide")), false)
  end)

  it("only ever classifies request events", function()
    assert.equal(event_model.is_dev_endpoint({ kind = "startup", path = "/__hydronium/watch" }), false)
    assert.equal(event_model.is_dev_endpoint({ kind = "reload" }), false)
    assert.equal(event_model.is_dev_endpoint(nil), false)
    assert.equal(event_model.is_dev_endpoint("nonsense"), false)
  end)

  it("parses --show-hmr, and defaults it off", function()
    assert.equal(must(main.parse_args({ "dev" })).show_hmr, false)
    assert.equal(must(main.parse_args({ "dev", "--show-hmr" })).show_hmr, true)
  end)
end)

describe("hydronium-cli drain -- durable log keeps what the views hide", function()
  local function encode(t)
    local json = require("hydronium_router.history.state")
    return json.encode(t)
  end

  --- A ctx with recording stubs for every collaborator drain touches.
  local function fake_ctx(opts)
    local logged, pushed, recorded = {}, {}, {}
    local lines = {}
    for _, e in ipairs(opts.events) do lines[#lines + 1] = encode(e) end
    return {
      show_hmr = opts.show_hmr,
      hidden_hmr = 0,
      skipped = 0,
      supervisor = { poll = function() return lines end },
      log = { append = function(_, e) logged[#logged + 1] = e.path or e.kind end },
      buffer = {
        push = function(_, e) pushed[#pushed + 1] = e.path or e.kind end,
        snapshot = function() return {} end,
      },
      state = {
        set_entries = function() end,
        set_hidden_hmr = function() end,
        record_request = function(_, e) recorded[#recorded + 1] = e.path or e.kind end,
        apply = function() end,
      },
    }, logged, pushed, recorded
  end

  local events = {
    { v = require("event_model").SCHEMA_VERSION, source = "meteorite", kind = "request", method = "GET", path = "/", status = 200, ts = 1 },
    { v = require("event_model").SCHEMA_VERSION, source = "meteorite", kind = "request", method = "GET", path = "/__hydronium/watch", status = 200, ts = 2 },
    { v = require("event_model").SCHEMA_VERSION, source = "meteorite", kind = "request", method = "GET", path = "/api/users", status = 200, ts = 3 },
    { v = require("event_model").SCHEMA_VERSION, source = "meteorite", kind = "request", method = "GET", path = "/__hydronium/dev/module/app", status = 200, ts = 4 },
  }

  it("hides dev-endpoint requests from both views but logs every one", function()
    local ctx, logged, pushed, recorded = fake_ctx({ events = events, show_hmr = false })
    main.drain(ctx)
    -- Durable log: the complete record, always.
    assert.same(logged, { "/", "/__hydronium/watch", "/api/users", "/__hydronium/dev/module/app" })
    -- Both views: application traffic only.
    assert.same(pushed, { "/", "/api/users" })
    assert.same(recorded, { "/", "/api/users" })
    -- Counted, so the UI can say so rather than the traffic just vanishing.
    assert.equal(ctx.hidden_hmr, 2)
  end)

  it("includes them everywhere under --show-hmr", function()
    local ctx, logged, pushed = fake_ctx({ events = events, show_hmr = true })
    main.drain(ctx)
    assert.equal(#logged, 4)
    assert.equal(#pushed, 4)
    assert.equal(ctx.hidden_hmr, 0)
  end)
end)
