local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert

local function shell_quote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function load_from_materialized_layout(entrypoint)
  local cwd = os.getenv("PWD")
  assert.is_not_nil(cwd, "PWD must be available to the test")
  local source_dir = cwd .. "/luax/src/hydronium_luax"
  local temp_dir = os.tmpname()
  os.remove(temp_dir)

  local mkdir_ok = os.execute("mkdir -p " .. shell_quote(temp_dir))
  assert.truthy(mkdir_ok == 0 or mkdir_ok == true, "failed to create temporary module root")
  local link_ok = os.execute(
    "ln -s " .. shell_quote(source_dir) .. " " .. shell_quote(temp_dir .. "/hydronium_luax")
  )
  assert.truthy(link_ok == 0 or link_ok == true, "failed to materialize installed-style module layout")

  local saved_path = package.path
  local saved_loaded = {}
  local saved_on_set_text = rawget(_G, "OnSetText")
  local saved_resolve_require = rawget(_G, "ResolveRequire")
  for name, value in pairs(package.loaded) do
    if name:match("^hydronium_luax") then
      saved_loaded[name] = value
      package.loaded[name] = nil
    end
  end

  package.path = temp_dir .. "/?.lua;" .. temp_dir .. "/?/init.lua"
  local ok, result = pcall(dofile, temp_dir .. "/hydronium_luax/" .. entrypoint)

  package.path = saved_path
  for name in pairs(package.loaded) do
    if name:match("^hydronium_luax") then
      package.loaded[name] = nil
    end
  end
  for name, value in pairs(saved_loaded) do
    package.loaded[name] = value
  end
  rawset(_G, "OnSetText", saved_on_set_text)
  rawset(_G, "ResolveRequire", saved_resolve_require)
  os.execute("rm -rf " .. shell_quote(temp_dir))

  assert.truthy(ok, "installed-layout bootstrap failed: " .. tostring(result))
  return result
end

describe("LUAX LuaLS installed-layout bootstrap", function()
  it("loads the configured luals/init.lua entrypoint outside a source tree", function()
    local plugin = load_from_materialized_layout("luals/init.lua")
    assert.equal(type(plugin.OnSetText), "function")
  end)

  it("loads the direct plugin.lua entrypoint outside a source tree", function()
    local plugin = load_from_materialized_layout("plugin.lua")
    assert.equal(type(plugin.OnSetText), "function")
  end)
end)
