--[[
  hydronium-cli build_runner -- M1's headless engine: loading a declared
  partiture.lua (decision #1: no partiture.lua is a clear error, never a
  guess), and the cooperative one-node-per-step coroutine driver M2's Ink
  view will also drive directly.

  Uses the REAL `ballad` (require("ballad"), require("ballad.partiture")),
  not a fake -- this module's entire job is gluing to that real library in
  process, so a fake would test nothing but this file's own assumptions
  about ballad's shape.
--]]

local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert

local build_runner = require("build_runner")
local partiture_mod = require("ballad.partiture")

local function must(value, message)
  if not value then
    error(message or "expected a value, got nil/false", 2)
  end
  return value
end

local TMP = os.getenv("TMPDIR") or "/tmp"

local function write_file(path, content)
  local f = must(io.open(path, "w"))
  f:write(content)
  f:close()
end

--- A real, minimal, on-disk partiture: one source node reading `*.txt`
--- files out of a real temp directory, one sink that does nothing with
--- them. Real files, real ballad.core.source/sink plugins -- nothing about
--- build_runner is faked.
--- @return string partiture_path
local function minimal_partiture_fixture()
  local root = TMP .. "/hy_build_runner_spec_root_" .. tostring(os.clock()):gsub("%.", "")
  os.execute("mkdir -p " .. root)
  write_file(root .. "/a.txt", "hello")
  local partiture_path = TMP .. "/hy_build_runner_spec_partiture_" .. tostring(os.clock()):gsub("%.", "") .. ".lua"
  write_file(partiture_path, string.format([[
    local ballad = require("ballad")
    return ballad.partiture(function(p)
      local src = p.source.files({ "*.txt" }, { root = %q })
      p.sink.none(src)
    end)
  ]], root))
  return partiture_path
end

--- A real Pipeline built in-process (not via a file) with one node that
--- deliberately fails via `ctx.fail`, for exercising Runner:step()'s
--- "error" status against a REAL ballad failure path (diagnostic.lua),
--- not a synthetic Lua error.
--- @return Pipeline
local function failing_pipeline()
  local failing_plugin = {
    name = "hy_build_runner_spec.failing",
    version = "0.0.1",
    methods = {
      boom = { inputs = { "asset_set" }, outputs = { "asset_set" }, cacheable = false, parallel_safe = true },
    },
    boom = function(ctx, _inputs, _opts)
      ctx.fail("deliberate test failure from hy_build_runner_spec")
    end,
  }
  return partiture_mod.build(function(p)
    local plug = p:use(failing_plugin)
    local src = p.source.files({ "*.txt" }, { root = "." })
    p.sink.none(plug.boom(src))
  end, 1, {})
end

describe("hydronium-cli build_runner.load", function()
  it("errors clearly when there is no partiture.lua at all -- never a guess", function()
    local missing = TMP .. "/hy_build_runner_spec_missing_" .. tostring(os.clock()):gsub("%.", "") .. "/partiture.lua"
    local p, err = build_runner.load(missing, 1, {})
    assert.is_nil(p)
    assert.truthy(err:find("no " .. missing, 1, true))
  end)

  it("errors clearly when the partiture file fails to evaluate", function()
    local bad = TMP .. "/hy_build_runner_spec_bad_" .. tostring(os.clock()):gsub("%.", "") .. ".lua"
    write_file(bad, "this is not { valid lua")
    local p, err = build_runner.load(bad, 1, {})
    assert.is_nil(p)
    assert.truthy(err, "expected an error message")
  end)

  it("loads a real, valid partiture into a Pipeline", function()
    local p = must(build_runner.load(minimal_partiture_fixture(), 1, {}))
    assert.is_table(p._graph)
  end)
end)

describe("hydronium-cli build_runner Runner", function()
  it("yields exactly once per planned node, matching plan().order with none missing or duplicated", function()
    local p = must(build_runner.load(minimal_partiture_fixture(), 1, {}))
    local rnr = build_runner.new_runner(p)
    local plan_order = rnr.plan.order
    assert.truthy(#plan_order > 0)

    local seen_started, seen_finished = {}, {}
    local yielded_count = 0
    while true do
      local status, result, events = rnr:step()
      for _, event in ipairs(events) do
        if event.kind == "node" and event.type == "task_started" then
          table.insert(seen_started, event.id)
        elseif event.kind == "node" and (event.type == "task_finished" or event.type == "task_skipped") then
          table.insert(seen_finished, event.id)
        end
      end
      if status ~= "yielded" then
        assert.equal(status, "done")
        assert.equal(#result, 1) -- one sink (p.sink.none)
        break
      end
      yielded_count = yielded_count + 1
    end

    -- One `coroutine.yield()` checkpoint per node (ballad's own
    -- pipeline.lua), so the coroutine reports "yielded" exactly
    -- #plan_order times before its FINAL resume (which runs past the last
    -- node's checkpoint, flushes, and returns "done") -- one more step than
    -- there are nodes, not one step per node.
    assert.equal(yielded_count, #plan_order, "one yield per planned node")
    assert.equal(#seen_started, #plan_order)
    assert.equal(#seen_finished, #plan_order)
    table.sort(seen_started)
    local sorted_order = {}
    for i, id in ipairs(plan_order) do sorted_order[i] = id end
    table.sort(sorted_order)
    assert.same(seen_started, sorted_order)
  end)

  it("drain() reaches the same 'done' result as manually stepping, and calls on_events for every batch", function()
    local p = must(build_runner.load(minimal_partiture_fixture(), 1, {}))
    local rnr = build_runner.new_runner(p)
    local total_events = 0
    local status, result = build_runner.drain(rnr, function(events)
      total_events = total_events + #events
    end)
    assert.equal(status, "done")
    assert.equal(#result, 1)
    assert.truthy(total_events >= #rnr.plan.order * 2, "expected at least a started+finished pair per node")
  end)

  it("surfaces a real ballad ctx.fail as an 'error' status, not a crash", function()
    local p = failing_pipeline()
    local rnr = build_runner.new_runner(p)
    local status, result = build_runner.drain(rnr)
    assert.equal(status, "error")
    local diagnostic = require("ballad.diagnostic")
    local message = diagnostic.is(result) and diagnostic.render(result) or tostring(result)
    assert.truthy(message:find("deliberate test failure", 1, true))
  end)

  it("does not leak ballad's own bare print() calls past the step -- restores the real print afterward", function()
    local p = must(build_runner.load(minimal_partiture_fixture(), 1, {}))
    local rnr = build_runner.new_runner(p)
    local original_print = print
    build_runner.drain(rnr)
    assert.equal(print, original_print, "global print must be restored after every step")
  end)
end)
