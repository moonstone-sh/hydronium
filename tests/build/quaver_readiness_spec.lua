-- Keeps the browser-shipped framework closure readable by a token-level
-- bundler/tree-shaker such as Quaver (docs/QUAVER_READINESS.md):
--   * reflective loaders and environment access (load, loadstring, loadfile,
--     dofile, setfenv, getfenv, debug) appear only in hydronium.compat;
--   * every require takes one string literal, except in the audited HMR
--     module that wraps `require` on purpose.
--   * no module names _G/_ENV (host bridges are hosts capabilities), except
--     the audited HMR module that wraps `require` on purpose.
local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert
local lexer = require("hydronium_luax.lexer")
local client_manifest = require("hydronium_dom.dev.client_manifest")
local flavor_files = require("hydronium.core.flavor_files")

local REFLECTIVE = {
  load = true, loadstring = true, loadfile = true, dofile = true,
  setfenv = true, getfenv = true, debug = true,
}
local REFLECTION_OWNERS = { ["hydronium.compat"] = true }
-- Wraps _G.require to observe module instantiation for HMR (dev only).
local REQUIRE_WRAPPERS = { ["hydronium.core.module_graph"] = true }
-- What Hydronium's own client bundle replaces with stubs.
local STUBS = {
  ["hydronium.test"] = true, ["hydronium.core.love_hmr"] = true,
  ["hydronium.core.source_topology"] = true, ["hydronium.core.source_inventory"] = true,
}

local function browser_modules()
  local seeds = { "hydronium", "hydronium_router", "hydronium_query", "hydronium_virtual", "hydronium_table" }
  local ids = {}
  for id in pairs(client_manifest.build(seeds)) do
    if not STUBS[id] then ids[#ids + 1] = id end
  end
  table.sort(ids)
  return ids
end

local function tokens_of(path)
  local f = io.open(path, "rb")
  local source = f:read("*a")
  f:close()
  local out = {}
  for _, t in ipairs(lexer.tokenize(source, "@" .. path, { include_whitespace = false })) do
    if t.type ~= "COMMENT" and t.type ~= "WHITESPACE" and t.type ~= "EOF" then out[#out + 1] = t end
  end
  return out
end

describe("browser closure is ready for a token-level bundler", function()
  local ids = browser_modules()

  it("covers the framework's browser runtime", function()
    assert.truthy(#ids > 40, "expected the full client closure, got " .. #ids)
  end)

  it("confines reflective loaders and environments to hydronium.compat", function()
    local problems = {}
    for _, id in ipairs(ids) do
      if not REFLECTION_OWNERS[id] then
        local tokens = tokens_of(flavor_files.searchpath(id, package.path))
        for i, t in ipairs(tokens) do
          local before = tokens[i - 1] and tokens[i - 1].value
          local after = tokens[i + 1] and tokens[i + 1].value
          local field = before == "." or before == ":"
          local key = (before == "{" or before == "," or before == ";") and after == "="
          if t.type == "IDENT" and REFLECTIVE[t.value] and not field and not key then
            problems[#problems + 1] = id .. ":" .. tostring(t.line) .. " uses " .. t.value
          end
        end
      end
    end
    assert.equal(#problems, 0, table.concat(problems, "\n"))
  end)

  it("reads no host bridge through the global environment", function()
    -- Every host bridge is a hydronium.runtime.hosts capability; browser code
    -- names _G/_ENV only in the audited HMR require wrapper.
    local problems = {}
    for _, id in ipairs(ids) do
      if not REQUIRE_WRAPPERS[id] then
        local tokens = tokens_of(flavor_files.searchpath(id, package.path))
        for i, t in ipairs(tokens) do
          local before = tokens[i - 1] and tokens[i - 1].value
          local field = before == "." or before == ":"
          if t.type == "IDENT" and not field and (t.value == "_G" or t.value == "_ENV") then
            problems[#problems + 1] = id .. ":" .. tostring(t.line) .. " uses " .. t.value
          end
        end
      end
    end
    assert.equal(#problems, 0, table.concat(problems, "\n"))
  end)

  it("requires only string literals", function()
    local problems = {}
    for _, id in ipairs(ids) do
      if not REQUIRE_WRAPPERS[id] then
        local tokens = tokens_of(flavor_files.searchpath(id, package.path))
        for i, t in ipairs(tokens) do
          local before = tokens[i - 1] and tokens[i - 1].value
          if t.type == "IDENT" and t.value == "require" and before ~= "." and before ~= ":" then
            local a, b, c = tokens[i + 1], tokens[i + 2], tokens[i + 3]
            local call = a and a.value == "(" and b and b.type == "STRING" and c and c.value == ")"
            local short = a and a.type == "STRING"
            if not (call or short) then
              problems[#problems + 1] = id .. ":" .. tostring(t.line) .. " uses require without a literal"
            end
          end
        end
      end
    end
    assert.equal(#problems, 0, table.concat(problems, "\n"))
  end)
end)

-- Every module of the dom and ink packages, server and terminal code
-- included, not just what the browser closure reaches. Each accepted
-- exception is named with its reason; an exception that no longer occurs
-- fails too, so this list stays an honest inventory (docs/QUAVER_READINESS.md).
local PACKAGE_EXCEPTIONS = {
  -- Generated manifests read at runtime on the server: data, not code.
  ["hydronium_dom.assets"] = { loadfile = true },
  ["hydronium_dom.server.client_boot"] = { loadfile = true },
  ["hydronium_dom.server.meteorite_routes"] = { loadfile = true },
  ["hydronium_dom.dev.source_registry"] = { loadfile = true },
  -- Island ids are dynamic entry points by design.
  ["hydronium_dom.server.island"] = { ["dynamic require"] = true },
  -- Read-only build-mode global set by Meteorite.
  ["hydronium_dom.server.meteorite"] = { _G = true, rawget = true },
  -- Dev-only sleep hook provided by Meteorite's dev server.
  ["hydronium_dom.dev.watch"] = { _G = true },
  -- Last-resort, checkout-only lookup of the Yoga library beside its own source,
  -- after the OS loader and MOONSTONE_PACKAGE_ROOT_HYDRONIUM_INK; harmless in a bundle.
  ["hydronium_ink.yoga_ffi"] = { debug = true },
}
-- ink is LuaJIT-only (terminal and Yoga through the FFI); dom must stay portable.
local FFI_PACKAGES = { hydronium_ink = true }

local function package_modules(dir)
  local ids = {}
  local handle = io.popen('find "' .. dir .. '" -name "*.lua" -not -name "*@*"')
  for path in handle:lines() do
    local id = path:sub(#dir + 2, -5):gsub("/init$", ""):gsub("/", ".")
    ids[#ids + 1] = { id = id, path = path }
  end
  handle:close()
  table.sort(ids, function(a, b) return a.id < b.id end)
  return ids
end

local function findings_of(path)
  local found = {}
  local tokens = tokens_of(path)
  for i, t in ipairs(tokens) do
    local before = tokens[i - 1] and tokens[i - 1].value
    local after = tokens[i + 1]
    if t.type == "IDENT" and before ~= "." and before ~= ":" then
      local key = (before == "{" or before == "," or before == ";") and after and after.value == "="
      if REFLECTIVE[t.value] and not key and before ~= "local" then found[t.value] = t.line end
      if t.value == "_G" or t.value == "_ENV" or t.value == "rawget" or t.value == "rawset" then found[t.value] = t.line end
      if t.value == "require" then
        local b, c = tokens[i + 2], tokens[i + 3]
        local call = after and after.value == "(" and b and b.type == "STRING" and c and c.value == ")"
        local short = after and after.type == "STRING"
        -- pcall(require, "literal"): an optional dependency, still static.
        local optional = before == "(" and tokens[i - 2] and tokens[i - 2].value == "pcall"
          and after and after.value == "," and b and b.type == "STRING"
        if not (call or short or optional) then found["dynamic require"] = t.line end
        local name = (call or optional) and b.value or (short and after.value)
        if name and name:match("^[\"']ffi[\"']$") then found.ffi = t.line end
      end
    end
  end
  return found
end

describe("dom and ink packages are ready for a token-level bundler", function()
  for _, dir in ipairs({ "dom/src", "ink/src" }) do
    it("allows only the listed exceptions in " .. dir, function()
      local problems, used = {}, {}
      local modules = package_modules(dir)
      assert.truthy(#modules > 10, "expected the package's modules, got " .. #modules)
      for _, m in ipairs(modules) do
        local allowed = PACKAGE_EXCEPTIONS[m.id] or {}
        for name, line in pairs(findings_of(m.path)) do
          local root = m.id:match("^[^.]+")
          if name == "ffi" and FFI_PACKAGES[root] then
            -- expected
          elseif allowed[name] then
            used[m.id .. " " .. name] = true
          else
            problems[#problems + 1] = m.id .. ":" .. tostring(line) .. " uses " .. name
          end
        end
      end
      local package_root = "hydronium_" .. dir:match("^(%w+)")
      for id, names in pairs(PACKAGE_EXCEPTIONS) do
        if id:match("^[^.]+") == package_root then
          for name in pairs(names) do
            if not used[id .. " " .. name] then
              problems[#problems + 1] = "stale exception: " .. id .. " no longer uses " .. name
            end
          end
        end
      end
      table.sort(problems)
      assert.equal(#problems, 0, table.concat(problems, "\n"))
    end)
  end
end)
