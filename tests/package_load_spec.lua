-- Every published Hydronium package needs one import-time check.  These are
-- deliberately direct requires rather than behavior tests: this gate catches
-- a package artifact that names a missing source file before consumers do.
local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert

local function require_from(source_root, module_name)
  local previous_path = package.path
  package.path = source_root .. "/?.lua;" .. source_root .. "/?/init.lua;" .. previous_path
  local ok, value = pcall(require, module_name)
  package.path = previous_path
  return ok, value
end

local packages = {
  { name = "hydronium" },
  { name = "hydronium_luax" },
  { name = "hydronium_dom" },
  { name = "hydronium_ink" },
  { name = "hydronium_lab" },
  { name = "hydronium_ink_lab" },
  { name = "hydronium_meteorite", source_root = "meteorite/src" },
  { name = "hydronium_oklab_utils" },
  { name = "hydronium_router" },
  { name = "hydronium_ballad" },
}

-- Executable packages do not expose a barrel module.  Require the modules
-- their entrypoints delegate to, so a renamed or omitted implementation file
-- fails in the normal repository suite rather than after publication.
local executable_modules = {
  { name = "create.init", source_root = "create/src" },
  { name = "create.luals", source_root = "create/src" },
  { name = "create.process", source_root = "create/src" },
  { name = "create.templates.minimal", source_root = "create/src" },
  { name = "create.templates.ssr", source_root = "create/src" },
  { name = "create.templates.islands", source_root = "create/src" },
  { name = "create.templates.ink", source_root = "create/src" },
  { name = "create.templates.love", source_root = "create/src" },
  { name = "create.templates.spa", source_root = "create/src" },
  { name = "create.writer", source_root = "create/src" },
  { name = "dev_log", source_root = "cli/src" },
  { name = "dev_supervisor", source_root = "cli/src" },
  { name = "event_model", source_root = "cli/src" },
  { name = "inspector", source_root = "cli/src" },
  { name = "ui.app", source_root = "cli/src" },
  { name = "ui.inspector_view", source_root = "cli/src" },
}

local executable_entrypoints = {
  "create/src/main.lua",
  "cli/src/main.lua",
}

describe("published package load smoke", function()
  for _, module_name in ipairs(packages) do
    it("loads " .. module_name.name, function()
      local ok, value
      if module_name.source_root then
        ok, value = require_from(module_name.source_root, module_name.name)
      else
        ok, value = pcall(require, module_name.name)
      end
      assert.truthy(ok, module_name.name .. " failed to load: " .. tostring(value))
      assert.truthy(value ~= nil, module_name.name .. " returned nil")
    end)
  end

  for _, module_name in ipairs(executable_modules) do
    it("loads executable implementation " .. module_name.name, function()
      local ok, value = require_from(module_name.source_root, module_name.name)
      assert.truthy(ok, module_name.name .. " failed to load: " .. tostring(value))
      assert.truthy(value ~= nil, module_name.name .. " returned nil")
    end)
  end

  for _, path in ipairs(executable_entrypoints) do
    it("parses executable entrypoint " .. path, function()
      local chunk, err = loadfile(path)
      assert.truthy(chunk ~= nil, path .. " failed to load: " .. tostring(err))
    end)
  end
end)
