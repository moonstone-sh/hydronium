--[[
  hydronium-cli build_verify -- M3: loading every produced hy_chunk asset
  in a fresh, isolated child Lua process and failing loudly if any of them
  do not load/execute cleanly.

  Generalizes examples/spa_hash_demo/verify_chunk_isolated.lua; these specs
  exercise the generalized module directly rather than re-running that
  example's real (slow, network/toolchain-dependent) build -- the CLI-level
  gate for the real example build is a `hydronium build` run against
  examples/spa_hash_demo, not a unit spec.
--]]

local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert

local build_verify = require("build_verify")

local function must(value, message)
  if not value then
    error(message or "expected a value, got nil/false", 2)
  end
  return value
end

local TMP = os.getenv("TMPDIR") or "/tmp"

local function write_file(content)
  local path = TMP .. "/hy_build_verify_spec_" .. tostring(os.clock()):gsub("%.", "") .. "_" .. tostring(math.random(1, 1e9)) .. ".lua"
  local f = must(io.open(path, "w"))
  f:write(content)
  f:close()
  return path
end

--- A fake Pipeline shaped just enough for M.collect_chunks: a `_graph.nodes`
--- map where at least one node's stored `.result.assets` holds a real
--- hy_chunk asset pointing at a real on-disk file.
local function fake_pipeline(chunk_paths)
  local nodes = {}
  for i, path in ipairs(chunk_paths) do
    nodes["n" .. i] = {
      result = { assets = { { kind = "hy_chunk", output_path = path, virtual_path = "client/c" .. i .. ".lua" } } },
    }
  end
  return { _graph = { nodes = nodes } }
end

describe("hydronium-cli build_verify.collect_chunks", function()
  it("finds hy_chunk assets across every node's stored result, deduplicated and sorted", function()
    local path = write_file("return 1")
    local p = fake_pipeline({ path, path }) -- same asset reachable from two nodes, e.g. bundle + site.manifest
    local chunks = build_verify.collect_chunks(p)
    assert.equal(#chunks, 1)
    assert.equal(chunks[1].output_path, path)
  end)

  it("ignores non-hy_chunk assets and assets with no output_path yet", function()
    local nodes = {
      n1 = { result = { assets = { { kind = "hy_module", output_path = "/tmp/whatever" } } } },
      n2 = { result = { assets = { { kind = "hy_chunk", output_path = nil } } } },
    }
    local chunks = build_verify.collect_chunks({ _graph = { nodes = nodes } })
    assert.equal(#chunks, 0)
  end)
end)

describe("hydronium-cli build_verify.verify", function()
  it("passes real, valid Lua chunks in a fresh isolated process", function()
    local good = write_file("local M = {} function M.hello() return 'hi' end return M")
    local ok, failures, checked = build_verify.verify(fake_pipeline({ good }))
    assert.truthy(ok)
    assert.equal(#failures, 0)
    assert.equal(checked, 1)
  end)

  it("fails loudly, with the real parse error, on a chunk that does not parse", function()
    local bad = write_file("this is not valid lua {{{")
    local ok, failures, checked = build_verify.verify(fake_pipeline({ bad }))
    assert.falsy(ok)
    assert.equal(checked, 1)
    assert.equal(#failures, 1)
    assert.equal(failures[1].chunk.output_path, bad)
    assert.truthy(failures[1].output:find("PARSE ERROR", 1, true))
  end)

  it("fails loudly on a chunk that parses but raises when executed", function()
    local bad = write_file("error('boom at runtime')")
    local ok, failures = build_verify.verify(fake_pipeline({ bad }))
    assert.falsy(ok)
    assert.truthy(failures[1].output:find("EXECUTE ERROR", 1, true))
    assert.truthy(failures[1].output:find("boom at runtime", 1, true))
  end)

  it("does not depend on this process's own LUA_PATH -- a chunk that only works by accidentally requiring a real hydronium module must fail", function()
    -- If verification ran in-process via a bare load()/pcall() instead of a
    -- real child process with LUA_PATH cleared, this would falsely PASS
    -- (this spec process's own LUA_PATH really does have hydronium_router
    -- on it). That is exactly the silent-failure class M3 exists to catch.
    local sneaky = write_file("require('hydronium_router') return {}")
    local ok, failures = build_verify.verify(fake_pipeline({ sneaky }))
    assert.falsy(ok, "a chunk that only works via this process's OWN LUA_PATH must fail isolated verification")
    assert.truthy(failures[1].output:find("hydronium_router", 1, true))
  end)

  it("reports true with zero checked when there is nothing to verify", function()
    local ok, failures, checked = build_verify.verify(fake_pipeline({}))
    assert.truthy(ok)
    assert.equal(#failures, 0)
    assert.equal(checked, 0)
  end)
end)
