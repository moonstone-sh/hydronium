-- A UI flow, never an authorization decision. The server owns sessions,
-- challenges, permission checks, expiry and audit events.
local H = require("hydronium")
---@type HydroniumAuthModule
local M = {}
function M.createFlow(options)
  options = options or {}
  if type(options.transport) ~= "function" then error("auth flow requires a transport", 2) end
  local state, set = H.createSignal({step=options.initial_step or "credentials", pending=false})
  local generation, alive, cancel = 0, true, nil
  local function stop()
    generation = generation + 1
    local previous = cancel; cancel = nil
    if previous then pcall(previous) end
  end
  local flow = {state=state}
  function flow:reset(step)
    if not alive then return end
    stop(); set({step=step or options.initial_step or "credentials", pending=false})
  end
  function flow:submit(operation, payload)
    if not alive or state().pending then return false end
    if options.validate then
      local ok, message = options.validate(operation, payload)
      if not ok then set({step=state().step,pending=false,error=message}); return false end
    end
    stop(); local current = generation; local settled = false
    local step = state().step
    set({step=step,pending=true})
    local function done(error_value, result)
      if settled or not alive or current ~= generation then return end
      settled = true; cancel = nil
      result = type(result) == "table" and result or {}
      if error_value ~= nil then set({step=step,pending=false,error=tostring(error_value)}); return end
      local next_step = result.step or step
      if options.steps and not options.steps[next_step] then
        set({step=step,pending=false,error="Authentication returned an unsupported step."}); return
      end
      set({step=next_step,pending=false,data=result.data,message=result.message})
    end
    local ok, cancellation = pcall(options.transport, operation, payload, done)
    if not ok then done("Could not complete this request. Please try again.")
    elseif type(cancellation) == "function" and not settled then
      if alive and current == generation then cancel = cancellation
      else pcall(cancellation) end
    end
    return true
  end
  function flow:dispose()
    if not alive then return end
    alive = false; stop()
  end
  if H.getScope() then H.onCleanup(function() flow:dispose() end) end
  return flow
end
M.create_flow = M.createFlow
return M
