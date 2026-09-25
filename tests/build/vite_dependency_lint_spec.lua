--[[
  Decoupling guardrail (STEP 3b of docs/HYDRONIUM_WEB_VITE_ADAPTER_PLAN.md).

  The user's explicit fear driving the whole Vite-adapter plan: "we would
  end up relying too much on vite, and couple hydronium HARD on it."
  Hydronium owns the asset-provider CONTRACT (hydronium_dom.assets,
  hy_asset_ref); Vite is one implementation of it, `require()`-reachable
  from exactly two files inside the guarded framework source tree (see
  ALLOWED below). This spec is a real, mechanical lint, not a policy
  comment: it fails the build the moment a THIRD file starts requiring
  Vite-specific tooling, the same day that happens.

  Scoped to real `require(...)` CALL TARGETS, not a raw substring search
  over file bytes -- a doc comment that mentions "vite_module.lua" or
  "@hydronium-js/vite" in prose (to explain what a neighboring file does,
  exactly as this codebase's own comments do throughout) is not a
  dependency and must not fail this lint; an actual `require(...)` (or its
  `require "..."` sugar) naming a Vite-specific module is.

  Scope: the framework packages listed in this workspace's own CLAUDE.md
  ("core/, router/, query/, table/, virtual/, ink/, luax/ and dom/ (except
  the adapter files) may never require vite_module / vite_assets /
  anything Vite-specific"). `build/` (hydronium_ballad) is NOT in this
  list -- `build/src/hydronium_ballad/plugins/vite_assets.lua` is the
  ballad-side half of the same adapter and is expected to require Vite
  concepts; `tests/build/vite_assets_spec.lua` covers it on its own terms.
--]]

local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert
local fs = require("ballad.fs")

-- The framework source roots this guardrail protects. Deliberately by
-- directory, not by moonstone package name, so a future package added
-- under one of these roots is covered automatically.
local GUARDED_DIRS = {
  "core/src",
  "router/src",
  "query/src",
  "table/src",
  "virtual/src",
  "ink/src",
  "luax/src",
  "dom/src",
}

-- The ONLY files inside the guarded tree allowed to `require()` something
-- Vite-specific -- the adapter's own resolver, and the ONE call site
-- (M2's ISLAND rendering branch) that resolves a JS island's module
-- through it. If a change needs to add an entry here for any OTHER file,
-- the new code almost certainly belongs in js/packages/vite or
-- build/src/hydronium_ballad/plugins instead -- see
-- docs/HYDRONIUM_WEB_VITE_ADAPTER_PLAN.md section 2 ("The boundary").
local ALLOWED = {
  ["dom/src/hydronium_dom/server/vite_module.lua"] = true,
  ["dom/src/hydronium_dom/server/init.lua"] = true,
}

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

--- Extracts every `require(...)`/`require "..."` call TARGET in `content`
--- -- deliberately not a whole-file substring search (see this file's own
--- header for why prose mentions must not trip this lint).
local function require_targets(content)
  local targets = {}
  for target in content:gmatch('require%s*%(%s*["\']([^"\']+)["\']') do
    targets[#targets + 1] = target
  end
  for target in content:gmatch('require%s+["\']([^"\']+)["\']') do
    targets[#targets + 1] = target
  end
  return targets
end

local function has_vite_require(content)
  for _, target in ipairs(require_targets(content)) do
    if target:find("vite", 1, true) then
      return target
    end
  end
  return nil
end

describe("decoupling guardrail: framework source stays Vite-agnostic", function()
  it("the allowlist itself points at real files (fails loudly if a file moves/is renamed)", function()
    for path in pairs(ALLOWED) do
      assert.truthy(read_file(path), path .. " does not exist -- update ALLOWED in this spec")
    end
  end)

  it("no guarded source file requires Vite-specific tooling outside the two allowed adapter files", function()
    local violations = {}
    for _, dir in ipairs(GUARDED_DIRS) do
      for _, file in ipairs(fs.list_files(dir)) do
        if (file:match("%.lua$") or file:match("%.luax$")) and not ALLOWED[file] then
          local content = read_file(file)
          if content then
            local hit = has_vite_require(content)
            if hit then
              table.insert(violations, file .. ": require(\"" .. hit .. "\")")
            end
          end
        end
      end
    end
    assert.equal(#violations, 0, "Vite-specific require() found outside the adapter boundary:\n"
      .. table.concat(violations, "\n"))
  end)

  it("hydronium_dom.assets (the neutral provider contract) itself requires no Vite-specific module", function()
    -- The whole point of STEP 1: the contract module's OWN require graph
    -- names no provider by module id -- "vite-dev"/"vite-manifest" are
    -- opaque strings a CALLER passes in as config values, never a
    -- `require()` target assets.lua reaches for itself.
    local content = read_file("dom/src/hydronium_dom/assets.lua")
    assert.truthy(content, "dom/src/hydronium_dom/assets.lua does not exist")
    assert.is_nil(has_vite_require(content))
  end)
end)
