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
  assert(#tmpls == 4, "expected 4 templates, got " .. #tmpls)
  local ids = {}
  for _, t in ipairs(tmpls) do
    ids[t.id] = true
  end
  assert(ids.ssr, "missing ssr template")
  assert(ids.islands, "missing islands template")
  assert(ids.minimal, "missing minimal template")
  assert(ids.ink, "missing ink template")
  -- `spa` is deliberately NOT listed -- see templates/spa.lua's own
  -- header comment and create.scaffold's explicit gate below. Corrected
  -- 2026-09-10: `mount()` and the client bundler ARE real now (the `ssr`
  -- template uses both), and hydronium-router is now real; what remains is
  -- a complete static build/delivery recipe without a Meteorite process.
  assert(not ids.spa, "spa should not be listed as an available template")
end)

test("scaffold dry-run produces a portable Ink terminal project", function()
  local res, err = create.scaffold({
    directory = "/tmp/test-hydronium-ink",
    template = "ink",
    name = "test-ink-app",
    dry_run = true,
  })
  assert(res ~= nil, "scaffold returned nil: " .. tostring(err))
  assert(res.next_script == "run", "ink should direct users to the run script")

  local file_map = {}
  for _, file in ipairs(res.created) do file_map[file.path] = true end
  assert(file_map["moonstone.toml"], "missing moonstone.toml")
  assert(file_map[".gitignore"], "missing .gitignore")
  assert(file_map["run.lua"], "missing run.lua")
  assert(file_map["src/App.luax"], "missing src/App.luax")
  assert(file_map["README.md"], "missing README.md")
  assert(file_map[".luarc.json"], "missing .luarc.json")
  local run_lua = require("create.templates.ink").files({ name = "test-ink-app" })["run.lua"]
  assert(run_lua and run_lua:find('require%("hydronium.core.hmr"%)'), "Ink run.lua must use shared core HMR")
  assert(run_lua:find("onTick", 1, true), "Ink run.lua must poll refreshes inside the renderer loop")
end)

test("Ink rejects non-LuaJIT interpreters before writing", function()
  local target = "/tmp/test-hydronium-ink-wrong-runtime"
  os.execute(string.format('rm -rf "%s"', target))
  local res, err = create.scaffold({
    directory = target,
    template = "ink",
    interpreter = "lua@5.4",
  })
  assert(res == nil, "expected Ink scaffold to reject PUC Lua")
  assert(err:find("luajit@2.1", 1, true), "error should name the supported interpreter")
  local exists = io.open(target .. "/moonstone.toml", "r")
  assert(exists == nil, "runtime rejection must happen before files are written")
  if exists then exists:close() end
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
  assert(file_map["src/views/Document.lua"], "missing src/views/Document.lua")
  assert(file_map["views/Document.luax"], "missing views/Document.luax")
  assert(file_map["views/App.luax"], "missing views/App.luax")
  assert(file_map["views/Counter.luax"], "missing views/Counter.luax")
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
  assert(file_map["views/Document.luax"], "missing views/Document.luax")
  assert(file_map["src/views/Document.lua"], "missing src/views/Document.lua")
  assert(file_map["public/js/bootstrap/bootstrap.js"], "missing public/js/bootstrap/bootstrap.js")
  assert(file_map["public/js/bootstrap/boundary_registry.js"], "missing public/js/bootstrap/boundary_registry.js")
  assert(file_map["public/js/bootstrap/priority.js"], "missing public/js/bootstrap/priority.js")
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

-- Regression guard for a real, verified editor behaviour: Meteorite
-- generates per-route LuaCATS classes into `.meteorite/aids/lua` on every
-- graph/build, and `MeteoriteApp`'s path-literal overloads really do give
-- `c` a specific type inside `app:get(path, function(c) ... end)` -- but
-- ONLY if those files are on LuaLS's path. They were not, in every real
-- scaffolded project checked. Measured with a real
-- textDocument/completion request against lua-language-server 3.18.2-dev,
-- at `c.params.` inside `app:get("/hydronium-src/:path*", function(c)`:
-- 100 junk word-completions before, exactly one (`path`) after.
test("luals.configure puts Meteorite's generated LuaCATS aids on the LuaLS path", function()
  local tmp_dir = os.tmpname()
  os.remove(tmp_dir)
  os.execute(string.format('mkdir -p "%s"', tmp_dir))

  local res, err = luals.configure(tmp_dir, { interpreter = "luajit@2.1", meteorite = true })
  assert(res ~= nil, "luals.configure failed: " .. tostring(err))

  local f = assert(io.open(tmp_dir .. "/.luarc.json", "r"))
  local content = f:read("*a")
  f:close()

  -- workspace.library makes LuaLS load the generated classes at all...
  assert(content:find("%.meteorite/aids/lua\""), "missing .meteorite/aids/lua workspace library entry")
  -- ...and runtime.path is what lets `require("meteorite")` resolve to the
  -- generated stub that declares those typed overloads.
  assert(content:find("%.meteorite/aids/lua/%?%.lua"), "missing .meteorite/aids/lua/?.lua runtime path entry")
  assert(content:find("%.meteorite/aids/lua/%?/init%.lua"), "missing .meteorite/aids/lua/?/init.lua runtime path entry")
  -- Adding the Meteorite searchers must NOT clobber the LUAX one. Two
  -- separate `runtime:at("path")` cursors silently did exactly that,
  -- because the second cursor does not observe the first's pending set().
  assert(content:find("%?%.luax"), "meteorite wiring clobbered the ?.luax searcher")

  os.execute(string.format('rm -rf "%s"', tmp_dir))
end)

test("luals.configure leaves non-Meteorite templates free of Meteorite aids", function()
  local tmp_dir = os.tmpname()
  os.remove(tmp_dir)
  os.execute(string.format('mkdir -p "%s"', tmp_dir))

  -- The `minimal` template's tooling: no luax, no meteorite.
  local res, err = luals.configure(tmp_dir, { interpreter = "lua@5.4", luax = false, meteorite = false })
  assert(res ~= nil, "luals.configure failed: " .. tostring(err))

  local f = assert(io.open(tmp_dir .. "/.luarc.json", "r"))
  local content = f:read("*a")
  f:close()

  assert(not content:find("%.meteorite/aids"), "non-Meteorite template should not reference Meteorite aids")

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
  assert(output:find("C\tink", 1, true), "missing ink completion")
  assert(not output:find("C\tminimal", 1, true), "minimal must be exposed as --minimal, not a template value")
end)

test("CLI exposes minimal as an exclusive flag", function()
  local minimal = assert(io.popen([[lua ./src/main.lua --minimal --dry-run 2>&1]]))
  local minimal_output = minimal:read("*a")
  assert(minimal:close(), "--minimal dry-run failed")
  assert(minimal_output:find("src/main.lua", 1, true), "--minimal did not select the minimal scaffold")
  assert(minimal_output:find("moon run run", 1, true), "--minimal printed the wrong next step")

  local mixed = assert(io.popen([[lua ./src/main.lua --minimal --template ink --dry-run 2>&1; printf '\n__EXIT__%s\n' "$?"]]))
  local mixed_output = mixed:read("*a")
  mixed:close()
  assert(mixed_output:find("__EXIT__1", 1, true), "--minimal with --template should fail")
  assert(mixed_output:find("cannot be combined", 1, true), "mixed selector error is unclear")

  local legacy = assert(io.popen([[lua ./src/main.lua --template minimal --dry-run 2>&1; printf '\n__EXIT__%s\n' "$?"]]))
  local legacy_output = legacy:read("*a")
  legacy:close()
  assert(legacy_output:find("__EXIT__1", 1, true), "--template minimal should be rejected")
  assert(legacy_output:find("selected with %-%-minimal"), "legacy selector error should direct users to --minimal")
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
  package.path = package.path .. ";../luax/src/?.lua;../luax/src/?/init.lua"
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

    local checked_lua, checked_luax, checked_js, checked_toml = 0, 0, 0, 0
    local ink_refresh_descriptors = 0

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
        if tmpl.id == "ink" and f.path == "src/App.luax" then
          ink_refresh_descriptors = compile_result.refresh and compile_result.refresh.rewritten or 0
        end
        checked_luax = checked_luax + 1
      elseif f.path:match("%.js$") then
        local result = os.execute(string.format('node --check "%s" >/dev/null 2>&1', f.full_path))
        assert(result == true or result == 0, "[" .. tmpl.id .. "] " .. f.path .. " failed node --check")
        checked_js = checked_js + 1
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
    assert(manifest:find('name = "moonstone/hydronium"', 1, true), "[" .. tmpl.id .. "] missing hydronium core dependency")
    if tmpl.id == "ssr" or tmpl.id == "islands" then
      assert(manifest:find('name = "moonstone/hydronium-luax"', 1, true), "[" .. tmpl.id .. "] missing hydronium-luax dependency")
      assert(manifest:find('name = "moonstone/hydronium-dom"', 1, true), "[" .. tmpl.id .. "] missing hydronium-dom dependency")
      if tmpl.id == "islands" then
        assert(checked_js > 0, "[islands] no generated browser JavaScript was syntax-checked")
      end
    elseif tmpl.id == "ink" then
      assert(checked_luax > 0, "[ink] no .luax files were compiled")
      assert(ink_refresh_descriptors > 0, "[ink] App signal is not eligible for state-preserving HMR")
      assert(manifest:find('name = "moonstone/hydronium%-ink"'), "[ink] missing hydronium-ink dependency")
      assert(manifest:find('name = "moonstone/hydronium%-ink".-constraint = "%^0%.1%.1"'), "[ink] must require the native-closure-aware hydronium-ink release")
      assert(manifest:find('name = "moonstone/hydronium%-luax"'), "[ink] missing hydronium-luax dependency")
      assert(manifest:find('name = "luajit"', 1, true), "[ink] interpreter must be LuaJIT")
      assert(manifest:find('version = "2.1.0"', 1, true), "[ink] must select LuaJIT 2.1.0")
      assert(manifest:find('abi = "5.1"', 1, true), "[ink] must select Lua ABI 5.1")
      assert(manifest:find('constraint = "%^0%.1%.0"'), "[ink] dependencies must use portable registry constraints")
      assert(not manifest:find('registry = "path"', 1, true), "[ink] must not require a monorepo checkout")
      assert(not manifest:find('path:', 1, true), "[ink] must not emit path constraints")
    end

    local luals_file = assert(io.open(dir .. "/.luarc.json", "r"))
    local luals_config = luals_file:read("*a")
    luals_file:close()
    if tmpl.id ~= "ink" then
      assert(luals_config:find("hydronium%-dom/types"), "[" .. tmpl.id .. "] missing packaged DOM types")
    else
      assert(luals_config:find("share/lua/5%.1"), "[ink] missing LuaJIT workspace library")
      assert(not luals_config:find("hydronium%-dom/types"), "[ink] must not configure DOM types")
    end
    if tmpl.id == "minimal" then
      assert(not luals_config:find("hydronium_luax", 1, true), "[minimal] must not configure an unavailable LUAX plugin")
      assert(not luals_config:find("ambient%-types"), "[minimal] must not opt into bare DOM globals")
    else
      assert(luals_config:find("hydronium_luax/luals/init.lua", 1, true), "[" .. tmpl.id .. "] missing LUAX plugin")
      assert(luals_config:find("hydronium%-luax/types"), "[" .. tmpl.id .. "] missing packaged LUAX types")
      if tmpl.id == "ink" then
        assert(not luals_config:find("ambient%-types"), "[ink] must not configure ambient DOM globals")
      else
        assert(luals_config:find("ambient%-types"), "[" .. tmpl.id .. "] missing bare DOM globals")
      end
    end

    os.execute(string.format('rm -rf "%s"', dir))
  end
end)

print(string.format("\nResults: %d/%d passed\n", passed, total))
if passed < total then
  os.exit(1)
end
