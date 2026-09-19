-- Host-neutral module replacement for a live Hydronium Lua VM.
--
-- Transports decide when source changed; hosts decide how to present success
-- or failure. This module owns only the transferable operation: compile a
-- replacement loader, install it under a stable require ID, reload its
-- component families, and summarize the refresh.
local family_loader = require("hydronium.core.family_loader")
local module_graph = require("hydronium.core.module_graph")

local M = {}

local function compile(module_id, source)
  if type(module_id) ~= "string" or module_id == "" then
    error("hydronium.core.hmr: module_id must be a non-empty string", 3)
  end
  if type(source) ~= "string" then
    error("hydronium.core.hmr: source for '" .. module_id .. "' must be a string", 3)
  end
  local load_fn = loadstring or load
  local chunk, err = load_fn(source, "@" .. module_id)
  if not chunk then
    error("hydronium.core.hmr: could not compile '" .. module_id .. "': " .. tostring(err), 3)
  end
  return chunk
end

--- Installs source as a package.preload module without requiring it.
--- Enable family_loader before the module's first require if it should be hot.
function M.install(module_id, source)
  package.preload[module_id] = compile(module_id, source)
end

local function summarize(outcome, results, extra)
  local summary = extra or {}
  summary.outcome = outcome
  summary.families, summary.refreshed, summary.failed = 0, 0, 0
  summary.results = results or {}
  for _, result in pairs(summary.results) do
    summary.families = summary.families + 1
    summary.refreshed = summary.refreshed + (result.refreshed or 0)
    summary.failed = summary.failed + (result.failed or 0)
  end
  return summary
end

--- Compile and apply a coherent module-source batch. Evaluation happens for
--- the complete planned region before any family refresh commits, so a failed
--- replacement retains all pre-existing live component scopes. Lua module
--- evaluation can have arbitrary external side effects; those cannot be
--- rolled back and are intentionally reported only as a best-effort boundary.
---
--- @param sources { [string]: string }
--- @param opts table? { root: any?, revision: string?, revisions: table? }
--- @return table outcome hot|installed|remount|restart|rejected
function M.apply_batch(sources, opts)
  opts = opts or {}
  if type(sources) ~= "table" then
    error("hydronium.core.hmr: sources must be a module-id keyed table", 2)
  end
  local compiled, changed = {}, {}
  for module_id, source in pairs(sources) do
    compiled[module_id] = compile(module_id, source)
    table.insert(changed, module_id)
  end
  table.sort(changed)
  if #changed == 0 then
    return summarize("installed", {}, { modules = {} })
  end

  local plan = module_graph.plan(changed, opts)
  -- The historical single-module primitive is intentionally low-level: it
  -- always evaluates its target so callers receive its compilation/evaluation
  -- error. Keep that contract while transports use apply_batch's safer
  -- planner-driven restart outcome.
  if opts.force and plan.outcome == "restart" then
    plan = { outcome = "hot", modules = changed, families = {} }
  end
  if plan.outcome == "restart" or plan.outcome == "rejected" then
    plan.results = {}
    plan.families, plan.refreshed, plan.failed = 0, 0, 0
    return plan
  end

  local previous_loaders = {}
  for module_id, loader in pairs(compiled) do
    previous_loaders[module_id] = package.preload[module_id]
    package.preload[module_id] = loader
  end
  if plan.outcome == "installed" then
    local revisions = opts.revisions or {}
    for module_id in pairs(sources) do
      local revision = revisions[module_id]
      if revision == nil then revision = opts.revision end
      module_graph.manage(module_id, { revision = revision })
    end
    return summarize("installed", {}, { modules = plan.modules, revision = opts.revision })
  end

  local staged, stage_err = family_loader.stage(plan.modules)
  if not staged then
    for module_id, loader in pairs(previous_loaders) do
      package.preload[module_id] = loader
    end
    return summarize("rejected", {}, { modules = plan.modules, reason = stage_err })
  end
  local results = family_loader.commit(staged)
  local revisions = opts.revisions or {}
  for module_id in pairs(sources) do
    local revision = revisions[module_id]
    if revision == nil then revision = opts.revision end
    local current = module_graph.get(module_id)
    module_graph.manage(module_id, {
      coverage = current and current.coverage or "managed",
      revision = revision,
    })
  end
  return summarize(plan.outcome, results, {
    modules = plan.modules,
    root = plan.root,
    revision = opts.revision,
  })
end

--- Replaces one already-loaded component module and refreshes its families.
--- Loader and package.loaded entries are restored if module evaluation fails.
function M.replace(module_id, source)
  local summary = M.apply_batch({ [module_id] = source }, { force = true })
  summary.module = module_id
  if summary.outcome == "rejected" then
    error("hydronium.core.hmr: replacement of '" .. module_id .. "' failed: " .. tostring(summary.reason), 2)
  end
  return summary
end

M.replace_many = M.apply_batch

return M
