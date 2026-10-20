-- Dialect compat modules and the Moonstone flavor-variant policy.
--
-- Every compat file (the untagged fallback and each variant the running
-- interpreter can use) is loaded straight from disk and checked against the
-- same expectations, so the fallback and `compat@lua54.lua` cannot drift.
-- Run this file under LuaJIT and under PUC Lua 5.4 to cover both:
--   moon exec -- luajit tests/runner.lua tests/core/compat_spec.lua
--   moon exec -- lua    tests/runner.lua tests/core/compat_spec.lua
local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert
local flavor_files = require("hydronium.core.flavor_files")

local IS_LUA54 = jit == nil and _VERSION == "Lua 5.4"

local function load_file(path)
  local chunk, err = loadfile(path)
  if not chunk then error(err, 0) end
  return chunk()
end

-- The files a given interpreter may legitimately load.
local function compat_files(dir)
  local files = { dir .. "/compat.lua" }
  if IS_LUA54 then files[#files + 1] = dir .. "/compat@lua54.lua" end
  return files
end

local PACKAGES = {
  { dir = "core/src/hydronium", api = { "function_arity", "function_location", "load", "tointeger", "unpack" } },
  { dir = "luax/src/hydronium_luax", api = { "load", "utf8_char" } },
}

local function sorted_keys(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

describe("compat modules", function()
  for _, package in ipairs(PACKAGES) do
    for _, path in ipairs(compat_files(package.dir)) do
      describe(path, function()
        local compat = load_file(path)

        it("exports exactly the documented API", function()
          assert.same(sorted_keys(compat), package.api)
        end)

        it("compiles text and runs it against the given environment only", function()
          local chunk = compat.load("return marker, print", "=compat", { marker = 42 })
          local marker, leaked = chunk()
          assert.equal(marker, 42)
          assert.equal(leaked, nil)
        end)

        it("runs against the globals when no environment is given", function()
          local chunk = compat.load("return type(print)", "=compat")
          assert.equal(chunk(), "function")
        end)

        it("reports syntax errors with the chunk name", function()
          local chunk, err = compat.load("return +", "@broken.lua")
          assert.equal(chunk, nil)
          assert.truthy(tostring(err):find("broken.lua", 1, true))
        end)

        it("refuses binary chunks and non-strings", function()
          local chunk = compat.load(string.dump(function() return 1 end), "=bin")
          assert.equal(chunk, nil)
          assert.equal((compat.load(function() return nil end)), nil)
        end)

        if compat.unpack then
          it("unpacks ranges, including trailing nils", function()
            assert.equal(select("#", compat.unpack({ 1, nil, 3 }, 1, 3)), 3)
            local a, b = compat.unpack({ "x", "y", "z" }, 2)
            assert.equal(a, "y")
            assert.equal(b, "z")
          end)
        end

        if compat.tointeger then
          it("returns the integer value of integral numbers and nil otherwise", function()
            assert.equal(string.format("%08x", compat.tointeger(4294967295)), "ffffffff")
            assert.equal(compat.tointeger(3.5), nil)
          end)
        end

        if compat.utf8_char then
          it("encodes code points and replaces out-of-range ones", function()
            assert.equal(compat.utf8_char(0x41), "A")
            assert.equal(compat.utf8_char(0xE9), "\195\169")
            assert.equal(compat.utf8_char(0x20AC), "\226\130\172")
            assert.equal(compat.utf8_char(0x1F600), "\240\159\152\128")
            assert.equal(compat.utf8_char(0x110000), "\239\191\189")
            assert.equal(compat.utf8_char(-1), "\239\191\189")
          end)
        end
      end)
    end
  end
end)

-- Every Hydronium package directory that ships Lua.
local SOURCE_ROOTS = {
  "auth/src", "build/src", "create/src", "cli/src", "core/src", "dom/src", "i18n/src", "ink/src", "ink-lab/src",
  "lab/src", "lab-cli/src", "luax/src", "meteorite/src", "oklab-utils/src", "query/src",
  "router/src", "table/src", "virtual/src",
}

local function tagged_files()
  local found = {}
  for _, root in ipairs(SOURCE_ROOTS) do
    local process = io.popen("find " .. root .. " -type f -name '*@*' 2>/dev/null")
    if process then
      for line in process:lines() do found[#found + 1] = line end
      process:close()
    end
  end
  table.sort(found)
  return found
end

local function exists(path)
  local f = io.open(path, "rb")
  if f then f:close(); return true end
  return false
end

describe("flavor variant policy", function()
  -- Browser bundles, the dev /hydronium-src route, the DOM Lab bundle and
  -- LuaLS (embedded Lua 5.4) all read Hydronium's files out of a consumer's
  -- environment, where Moonstone keeps only the HOST interpreter's variant.
  -- A `@luajit` file there would reach a Lua 5.4 engine, so `@lua54` is the
  -- only tag Hydronium may ship, always beside an untagged fallback.
  it("keeps browser variants portable and native OS variants at explicit boundaries", function()
    local problems = {}
    for _, path in ipairs(tagged_files()) do
      local base, tags = flavor_files.split_file(path)
      if base then
        local native_windows = (#tags == 1 and tags[1] == "windows") and (
          path == "cli/src/dev_host@windows.lua" or path == "create/src/create/host@windows.lua"
          or path == "ink/src/hydronium_ink/clock@windows.lua"
          or path == "ink/src/hydronium_ink/tty_ffi@windows.lua"
          or path == "ink/src/hydronium_ink/source_files@windows.lua")
        if not flavor_files.matches_browser(tags) and not native_windows then
          problems[#problems + 1] = path .. ": unsupported variant outside a native platform boundary"
        elseif not exists(base) then
          problems[#problems + 1] = path .. ": missing untagged fallback " .. base
        end
      end
    end
    assert.equal(#problems, 0, table.concat(problems, "\n"))
  end)

  it("finds the compat variants it governs", function()
    local files = table.concat(tagged_files(), "\n")
    assert.truthy(files:find("core/src/hydronium/compat@lua54.lua", 1, true))
    assert.truthy(files:find("luax/src/hydronium_luax/compat@lua54.lua", 1, true))
  end)
end)

describe("hydronium.core.flavor_files", function()
  it("parses variant ids and files with Moonstone's tag rules", function()
    local base, tags = flavor_files.split_module_id("hydronium.compat@lua54")
    assert.equal(base, "hydronium.compat")
    assert.same(tags, { "lua54" })
    assert.same({ flavor_files.split_file("a/b/fs@lua51@linux.lua") }, { "a/b/fs.lua", { "lua51", "linux" } })
    assert.equal(flavor_files.split_file("a/mail@example.lua"), nil) -- unknown tag: ordinary file
    assert.equal(flavor_files.split_file("a/fs@linux@lua54.lua"), nil) -- out of order: not a variant
    assert.equal(flavor_files.split_file("a/parser_luajit.lua"), nil)
  end)

  it("prefers the @lua54 sibling for the browser and finds variant-only modules", function()
    local dir = os.tmpname()
    os.remove(dir)
    os.execute("mkdir -p '" .. dir .. "/pkg'")
    local function write(name, text)
      local f = io.open(dir .. "/pkg/" .. name, "w")
      f:write(text)
      f:close()
    end
    write("a.lua", "return 'a'")
    write("a@lua54.lua", "return 'a54'")
    write("b.lua", "return 'b'")
    write("b@luajit.lua", "return 'bjit'")
    write("c@lua54.lua", "return 'c54'")
    local path = dir .. "/?.lua;" .. dir .. "/?/init.lua"
    assert.equal(flavor_files.searchpath("pkg.a", path), dir .. "/pkg/a@lua54.lua")
    assert.equal(flavor_files.searchpath("pkg.b", path), dir .. "/pkg/b.lua")
    assert.equal(flavor_files.searchpath("pkg.c", path), dir .. "/pkg/c@lua54.lua")
    assert.equal(flavor_files.searchpath("pkg.missing", path), nil)
    assert.equal(flavor_files.browser_path(dir .. "/pkg/a@lua54.lua"), dir .. "/pkg/a@lua54.lua")
    os.execute("rm -rf '" .. dir .. "'")
  end)

  it("collapses module records to what the browser loads", function()
    local records = {
      { module_id = "x.compat" }, { module_id = "x.compat@lua54" }, { module_id = "x.compat@luajit" },
      { module_id = "x.other" }, { module_id = "x.only@luajit" },
    }
    local ids = {}
    for _, record in ipairs(flavor_files.select_browser_modules(records)) do ids[#ids + 1] = record.module_id end
    assert.same(ids, { "x.compat", "x.other" })
    assert.equal(records[2].module_id, "x.compat") -- the @lua54 record now carries the plain id
  end)
end)

describe("hydronium.compat (resolved through package.path)", function()
  it("is the untagged fallback in this workspace and agrees with the interpreter", function()
    local compat = require("hydronium.compat")
    assert.equal(compat.unpack, table.unpack or unpack)
  end)
end)

describe("hydronium.compat.function_location", function()
  for _, path in ipairs(compat_files("core/src/hydronium")) do
    it("reports where a Lua function is defined (" .. path .. ")", function()
      local compat = load_file(path)
      local source, line = compat.function_location(function() end)
      assert.truthy(source and source:find("compat_spec.lua", 1, true), tostring(source))
      assert.equal(type(line), "number")
      assert.equal(compat.function_location(print), nil)
      assert.equal(compat.function_location("not a function"), nil)
    end)
  end
end)

describe("hydronium.compat.function_arity", function()
  for _, path in ipairs(compat_files("core/src/hydronium")) do
    it("reports declared parameters where the runtime can (" .. path .. ")", function()
      local compat = load_file(path)
      local n, vararg = compat.function_arity(function(a, b) return a, b end)
      if n == nil then
        -- PUC 5.1's debug.getinfo has no nparams; callers treat nil as unknown.
        assert.equal(_VERSION, "Lua 5.1")
      else
        assert.equal(n, 2)
        assert.equal(vararg, false)
        local m, rest = compat.function_arity(function(a, ...) return a, ... end)
        assert.equal(m, 1)
        assert.equal(rest, true)
      end
      assert.equal(compat.function_arity("not a function"), nil)
    end)
  end
end)

-- Focused imports must not instantiate optional compiler/debug capabilities.
describe("focused compatibility capabilities", function()
  it("loads primitive helpers without loader or diagnostics dependencies", function()
    local ids = { "hydronium.compat.primitives", "hydronium.compat.loader", "hydronium.compat.diagnostics" }
    local saved, preloads = {}, {}
    for _, id in ipairs(ids) do saved[id], preloads[id] = package.loaded[id], package.preload[id]; package.loaded[id] = nil end
    package.preload[ids[2]] = function() error("primitive import reached text compilation") end
    package.preload[ids[3]] = function() error("primitive import reached debug reflection") end
    local ok, primitives = pcall(require, ids[1])
    local untouched = package.loaded[ids[2]] == nil and package.loaded[ids[3]] == nil
    for _, id in ipairs(ids) do package.loaded[id], package.preload[id] = saved[id], preloads[id] end
    assert.truthy(ok, tostring(primitives))
    assert.truthy(untouched)
    assert.same(sorted_keys(primitives), { "tointeger", "unpack" })
    assert.equal(primitives.unpack, table.unpack or unpack)
    assert.equal(select("#", primitives.unpack({ 1, nil, 3 }, 1, 3)), 3)
    assert.equal(primitives.tointeger(3.5), nil)
    assert.equal(primitives.tointeger(math.huge), nil)
    assert.equal(primitives.tointeger(0/0), nil)
  end)

  it("keeps the facade's functions identical to the focused exports", function()
    local compat = require("hydronium.compat")
    local primitives = require("hydronium.compat.primitives")
    local loader = require("hydronium.compat.loader")
    local diagnostics = require("hydronium.compat.diagnostics")
    assert.equal(compat.unpack, primitives.unpack)
    assert.equal(compat.tointeger, primitives.tointeger)
    assert.equal(compat.load, loader.load)
    assert.equal(compat.function_location, diagnostics.function_location)
    assert.equal(compat.function_arity, diagnostics.function_arity)
  end)

  it("has equivalent Lua 5.4 primitive and loader variants", function()
    if not IS_LUA54 then return end
    local primitives = load_file("core/src/hydronium/compat/primitives@lua54.lua")
    local loader = load_file("core/src/hydronium/compat/loader@lua54.lua")
    assert.same(sorted_keys(primitives), { "tointeger", "unpack" })
    assert.same(sorted_keys(loader), { "load" })
    assert.equal(primitives.unpack, table.unpack)
    assert.equal(primitives.tointeger, math.tointeger)
    local fn = loader.load("return value, print", "=focused", { value=7 })
    local value, global = fn()
    assert.equal(value, 7)
    assert.equal(global, nil)
    assert.equal(loader.load(string.dump(function() end)), nil)
  end)

  it("diagnostics continue to degrade without a debug library", function()
    local diagnostics = require("hydronium.compat.diagnostics")
    local previous = debug
    debug = nil
    local ok, location, arity = pcall(function()
      return diagnostics.function_location(function() end), diagnostics.function_arity(function() end)
    end)
    debug = previous
    assert.truthy(ok)
    assert.equal(location, nil)
    assert.equal(arity, nil)
  end)
end)
