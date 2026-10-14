-- Keeps the browser-shipped framework closure readable by a token-level
-- bundler/tree-shaker such as Quaver (docs/QUAVER_READINESS.md):
--   * reflective loaders and environment access (load, loadstring, loadfile,
--     dofile, setfenv, getfenv, debug) appear only in hydronium.compat;
--   * every require takes one string literal, except in the audited HMR
--     module that wraps `require` on purpose.
-- `_G.<name>` reads of host bridge globals are documented, not banned here.
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
