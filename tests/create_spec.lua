package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local create = require("create.init")
local luals = require("create.luals")

local total = 0
local passed = 0

local function test(name, fn)
  total = total + 1
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("  ✓ " .. name)
  else
    print("  ✗ " .. name)
    print("    Error: " .. tostring(err))
  end
end

print("\n--- hydronium-create unit tests ---")

test("available_templates lists all supported templates", function()
  local tmpls = create.available_templates()
  assert(#tmpls == 3, "expected 3 templates, got " .. #tmpls)
  local ids = {}
  for _, t in ipairs(tmpls) do
    ids[t.id] = true
  end
  assert(ids.ssr, "missing ssr template")
  assert(ids.islands, "missing islands template")
  assert(ids.minimal, "missing minimal template")
  -- `spa` is deliberately NOT listed -- see templates/spa.lua's own
  -- header comment and create.scaffold's explicit gate below. Nothing it
  -- promised (h.mount, a client bundler, a `hydronium` CLI binary) is
  -- real in the framework today.
  assert(not ids.spa, "spa should not be listed as an available template")
end)

test("scaffold rejects the disabled spa template with a clear error", function()
  local res, err = create.scaffold({
    directory = "/tmp/test-hydronium-spa",
    template = "spa",
    dry_run = true,
  })
  assert(res == nil, "expected spa scaffold to be refused")
  assert(err:find("not yet supported"), "expected a 'not yet supported' error message, got: " .. tostring(err))
end)

test("scaffold dry-run produces expected files for ssr template", function()
  local res, err = create.scaffold({
    directory = "/tmp/test-hydronium-app",
    template = "ssr",
    name = "test-ssr-app",
    dry_run = true,
  })
  assert(res ~= nil, "scaffold returned nil: " .. tostring(err))
  assert(res.project_name == "test-ssr-app")
  assert(res.template == "ssr")

  local file_map = {}
  for _, f in ipairs(res.created) do
    file_map[f.path] = true
  end
  assert(file_map["moonstone.toml"], "missing moonstone.toml")
  assert(file_map["src/main.lua"], "missing src/main.lua")
  assert(file_map["src/views/App.lua"], "missing src/views/App.lua")
  assert(file_map["views/App.luax"], "missing views/App.luax")
  assert(file_map["public/style.css"], "missing public/style.css")
  assert(file_map["build.zig"], "missing build.zig")
  assert(not file_map["src/hydronium"], "generated projects must resolve Hydronium through dependencies, not a source symlink")
end)

test("scaffold dry-run produces expected files for islands template", function()
  local res, err = create.scaffold({
    directory = "/tmp/test-hydronium-islands",
    template = "islands",
    name = "test-islands-app",
    dry_run = true,
  })
  assert(res ~= nil, "scaffold returned nil: " .. tostring(err))
  local file_map = {}
  for _, f in ipairs(res.created) do
    file_map[f.path] = true
  end
  assert(file_map["views/App.luax"], "missing views/App.luax")
  assert(file_map["src/views/App.lua"], "missing src/views/App.lua")
  assert(file_map["public/js/bootstrap/bootstrap.js"], "missing public/js/bootstrap/bootstrap.js")
  assert(file_map["public/js/bootstrap/boundary_registry.js"], "missing public/js/bootstrap/boundary_registry.js")
  assert(file_map["public/js/island/counter.js"], "missing public/js/island/counter.js")
end)

test("scaffold rejects invalid template name", function()
  local res, err = create.scaffold({
    directory = "/tmp/test-invalid",
    template = "non-existent-template",
    dry_run = true,
  })
  assert(res == nil, "expected error for unknown template")
  assert(err:find("Unknown template"), "expected Unknown template error message")
end)

test("luals.configure uses alter to update .luarc.json with Hydronium LuaX plugin", function()
  local tmp_dir = os.tmpname()
  os.remove(tmp_dir)
  os.execute(string.format('mkdir -p "%s"', tmp_dir))

  local res, err = luals.configure(tmp_dir, {
    interpreter = "lua@5.4",
  })
  assert(res ~= nil, "luals.configure failed: " .. tostring(err))
  assert(res.changed == true, "expected changed to be true")

  local f = io.open(tmp_dir .. "/.luarc.json", "r")
  assert(f ~= nil, "could not open generated .luarc.json")
  local content = f:read("*a")
  f:close()

  assert(content:find("hydronium_luax/luals/init.lua"), "missing hydronium_luax plugin in .luarc.json")
  assert(content:find("%.moonstone/env/share/lua/5.4"), "missing workspace library in .luarc.json")
  assert(content:find("hydronium%-luax/types"), "missing packaged LUAX types in .luarc.json")
  assert(content:find("hydronium%-dom/types"), "missing packaged DOM types in .luarc.json")
  assert(content:find("%*%.luax"), "missing *.luax association in .luarc.json")

  -- Idempotency check: running again should succeed without redundant duplicates
  local res2, err2 = luals.configure(tmp_dir, {
    interpreter = "lua@5.4",
  })
  assert(res2 ~= nil, "idempotent luals.configure failed: " .. tostring(err2))

  os.execute(string.format('rm -rf "%s"', tmp_dir))
end)

test("luals.configure composes with commented user config idempotently", function()
  local tmp_dir = os.tmpname()
  os.remove(tmp_dir)
  os.execute(string.format('mkdir -p "%s"', tmp_dir))

  local config = assert(io.open(tmp_dir .. "/.luarc.json", "w"))
  config:write([[// keep this project note
{
  "runtime": {
    "plugin": "existing-plugin.lua",
    "path": ["?.lua", "custom/?.lua"]
  },
  "workspace": { "library": ["existing-types"] }
}
]])
  config:close()

  local first, first_err = luals.configure(tmp_dir, {
    interpreter = "luajit@2.1",
    luax = true,
    dom = true,
    bare_dom = true,
  })
  assert(first ~= nil, "first configure failed: " .. tostring(first_err))
  assert(first.changed == true, "first configure should mutate the user config")

  local second, second_err = luals.configure(tmp_dir, {
    interpreter = "luajit@2.1",
    luax = true,
    dom = true,
    bare_dom = true,
  })
  assert(second ~= nil, "second configure failed: " .. tostring(second_err))
  assert(second.changed == false, "second configure must be idempotent")

  local configured = assert(io.open(tmp_dir .. "/.luarc.json", "r"))
  local content = configured:read("*a")
  configured:close()
  assert(content:find("// keep this project note", 1, true), "Alter must preserve JSONC comments")
  assert(content:find("existing%-plugin%.lua"), "Alter must preserve an existing plugin")
  assert(content:find("custom/%?%.lua"), "Alter must preserve custom runtime search paths")
  assert(content:find("%?%.luax"), "Alter must compose the LUAX runtime search path")
  assert(content:find("hydronium_luax/luals/init.lua", 1, true), "Hydronium plugin was not composed")
  assert(content:find("existing%-types"), "Alter must preserve existing workspace libraries")
  assert(content:find("ambient%-types"), "bare DOM types were not composed")

  os.execute(string.format('rm -rf "%s"', tmp_dir))
end)

test("CLI declarations and completion run on Clingy 0.4", function()
  local handle = assert(io.popen([[lua ./src/main.lua --__clingy-complete bash hydronium-create --template '' --cword=3]]))
  local output = handle:read("*a")
  local closed = handle:close()
  assert(closed, "hydronium-create completion process failed")
  assert(output:find("V\t2", 1, true), "missing Clingy completion protocol header")
  assert(output:find("C\tssr", 1, true), "missing ssr completion")
  assert(output:find("C\tislands", 1, true), "missing islands completion")
  assert(output:find("C\tminimal", 1, true), "missing minimal completion")
end)

--------------------------------------------------------------------------------
-- Content-validity regression gate.
--
-- Everything above this line only ever checked WHICH files get created,
-- never whether their CONTENT was valid Lua/LUAX or a valid moonstone.toml
-- -- exactly how all four templates shipped broken (arrow-function syntax
-- that doesn't exist in LUAX, a fictional Meteorite API, a bare
-- `[dependencies]` table header invalid for manifest_version 2, ...) for a
-- full audit cycle with a fully green test suite the whole time. This test
-- scaffolds every template for real and actually loads/compiles every
-- generated file, so a template that regresses back into "creates files
-- that don't parse" fails HERE, not in a human's hands.
--
-- Real, observed history of this exact test (not hypothetical): before
-- templates/ssr.lua and templates/islands.lua were rewritten, this test
-- failed red on both -- ssr.lua's `views/App.luax` used `() => ...` arrow
-- functions hydronium_luax.compile rejects outright, and islands.lua's
-- `moonstone.toml` had no bare `[dependencies]` bug (it used the equally
-- fictional `{path = "../hydronium"}` object form under `[dependencies]`,
-- which IS a bare single-bracket header) -- and passed green only after
-- those templates were fixed to use the real Meteorite/Hydronium APIs
-- verified via a live build/run/curl (ssr) and a live build/run/Playwright
-- click (islands).
--------------------------------------------------------------------------------

test("every template's generated content actually parses/compiles (content-validity gate)", function()
  -- The compiler is now an independent library package with its own top-level
  -- namespace, matching the module identity Moonstone materializes for
  -- generated projects.
  package.path = package.path .. ";../hydronium/luax/src/?.lua;../hydronium/luax/src/?/init.lua"
  local luax = require("hydronium_luax")
  local load_fn = loadstring or load

  local function has_bare_dependencies_header(toml_content)
    for line in toml_content:gmatch("[^\n]+") do
      -- Matches a bare `[dependencies]` line but NOT `[[dependencies]]`
      -- (the real, only-valid array-of-tables form for manifest_version 2)
      -- -- the leading `^%[` would also match the first `[` of `[[`, so
      -- this specifically rejects a second `[` or a non-`]` character
      -- right after the tag name from counting as a match.
      local trimmed = line:gsub("%s+$", "")
      if trimmed:match("^%[dependencies%]$") then
        return true
      end
    end
    return false
  end

  local templates = create.available_templates()
  assert(#templates > 0, "no templates to validate")

  for _, tmpl in ipairs(templates) do
    local dir = "/tmp/test-hydronium-content-gate-" .. tmpl.id
    os.execute(string.format('rm -rf "%s" && mkdir -p "%s"', dir, dir))

    local res, err = create.scaffold({
      directory = dir,
      template = tmpl.id,
      name = "content-gate-" .. tmpl.id,
      force = true,
    })
    assert(res ~= nil, "scaffold failed for template '" .. tmpl.id .. "': " .. tostring(err))

    local checked_lua, checked_luax, checked_toml = 0, 0, 0

    for _, f in ipairs(res.created) do
      if f.path:match("%.lua$") then
        local fh = assert(io.open(f.full_path, "r"), "could not open " .. f.full_path)
        local content = fh:read("*a")
        fh:close()
        local chunk, load_err = load_fn(content, "@" .. f.full_path)
        assert(chunk, "[" .. tmpl.id .. "] " .. f.path .. " failed to load as Lua: " .. tostring(load_err))
        checked_lua = checked_lua + 1
      elseif f.path:match("%.luax$") then
        local fh = assert(io.open(f.full_path, "r"), "could not open " .. f.full_path)
        local content = fh:read("*a")
        fh:close()
        local ok, compile_result = pcall(function()
          return luax.compile(content, { filename = f.path, runtime = "hydronium", development = false })
        end)
        assert(ok, "[" .. tmpl.id .. "] " .. f.path .. " failed to compile: " .. tostring(compile_result))
        checked_luax = checked_luax + 1
      elseif f.path == "moonstone.toml" then
        local fh = assert(io.open(f.full_path, "r"), "could not open " .. f.full_path)
        local content = fh:read("*a")
        fh:close()
        assert(not has_bare_dependencies_header(content),
          "[" .. tmpl.id .. "] moonstone.toml has a bare [dependencies] table header -- only [[dependencies]] is valid for manifest_version = 2")
        checked_toml = checked_toml + 1
      end
    end

    assert(checked_lua > 0, "[" .. tmpl.id .. "] no .lua files were checked -- test may be miswired")
    assert(checked_toml == 1, "[" .. tmpl.id .. "] expected exactly one moonstone.toml, checked " .. checked_toml)

    local manifest_file = assert(io.open(dir .. "/moonstone.toml", "r"))
    local manifest = manifest_file:read("*a")
    manifest_file:close()
    assert(not manifest:find("symlink_to", 1, true), "[" .. tmpl.id .. "] manifest must not use source symlinks")
    assert(manifest:find('name = "hydronium"', 1, true), "[" .. tmpl.id .. "] missing hydronium core dependency")
    if tmpl.id == "ssr" or tmpl.id == "islands" then
      assert(manifest:find('name = "hydronium-luax"', 1, true), "[" .. tmpl.id .. "] missing hydronium-luax dependency")
      assert(manifest:find('name = "hydronium-dom"', 1, true), "[" .. tmpl.id .. "] missing hydronium-dom dependency")
    end

    local luals_file = assert(io.open(dir .. "/.luarc.json", "r"))
    local luals_config = luals_file:read("*a")
    luals_file:close()
    assert(luals_config:find("hydronium%-dom/types"), "[" .. tmpl.id .. "] missing packaged DOM types")
    if tmpl.id == "minimal" then
      assert(not luals_config:find("hydronium_luax", 1, true), "[minimal] must not configure an unavailable LUAX plugin")
      assert(not luals_config:find("ambient%-types"), "[minimal] must not opt into bare DOM globals")
    else
      assert(luals_config:find("hydronium_luax/luals/init.lua", 1, true), "[" .. tmpl.id .. "] missing LUAX plugin")
      assert(luals_config:find("hydronium%-luax/types"), "[" .. tmpl.id .. "] missing packaged LUAX types")
      assert(luals_config:find("ambient%-types"), "[" .. tmpl.id .. "] missing bare DOM globals")
    end

    os.execute(string.format('rm -rf "%s"', dir))
  end
end)

print(string.format("\nResults: %d/%d passed\n", passed, total))
if passed < total then
  os.exit(1)
end
