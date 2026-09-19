-- Host-side HMR boundary coordinator.
-- A browser, terminal loop, or LÖVE update callback queues source changes
-- whenever it observes them, then calls :flush() at its own safe boundary
-- (between frames/events, never while rendering or dispatching input).

local hmr = require("hydronium.core.hmr")

local M = {}

function M.new(opts)
  opts = opts or {}
  local self = {
    pending = {},
    root = opts.root,
    on_remount = opts.on_remount,
    on_restart = opts.on_restart,
    last_revision = nil,
  }

  function self:queue(module_id, source, revision)
    if type(module_id) ~= "string" or type(source) ~= "string" then
      error("hydronium.core.hmr_host: queue requires string module_id and source", 2)
    end
    if revision ~= nil and type(revision) ~= "string" then
      error("hydronium.core.hmr_host: revision must be a string when provided", 2)
    end
    self.pending[module_id] = { source = source, revision = revision }
  end

  function self:queue_batch(sources, opts)
    if type(sources) ~= "table" then
      error("hydronium.core.hmr_host: queue_batch requires a module-id keyed table", 2)
    end
    opts = opts or {}
    for module_id, source in pairs(sources) do
      local revision = opts.revisions and opts.revisions[module_id] or opts.revision
      self:queue(module_id, source, revision)
    end
  end

  function self:flush(revision)
    if next(self.pending) == nil then return nil end
    local pending = self.pending
    self.pending = {}
    if revision ~= nil and type(revision) ~= "string" then
      error("hydronium.core.hmr_host: flush revision must be a string when provided", 2)
    end
    if revision ~= nil and revision == self.last_revision then
      return { outcome = "skipped", reason = "duplicate_revision", revision = revision }
    end

    local sources, revisions = {}, {}
    for module_id, update in pairs(pending) do
      sources[module_id] = update.source
      revisions[module_id] = update.revision
    end
    local result = hmr.apply_batch(sources, {
      root = self.root,
      revision = revision,
      revisions = revisions,
    })
    if result.outcome ~= "rejected" and result.outcome ~= "restart" then
      self.last_revision = revision
    end
    if result.outcome == "remount" and self.on_remount then self.on_remount(result) end
    if result.outcome == "restart" and self.on_restart then self.on_restart(result) end
    return result
  end

  return self
end

return M
