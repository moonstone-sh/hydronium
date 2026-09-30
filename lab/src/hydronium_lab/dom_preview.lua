-- One preview controller per browser VM; shared args never cross a server VM.
local H = require("hydronium")
local lab = require("hydronium_lab")
local M = {}
local controller

local function defaults(story)
  local args = lab.copy(story.args)
  for key, control in pairs(story.controls) do
    if args[key] == nil then args[key] = control.default end
  end
  return args
end

function M.App(props)
  local registry = require("hydronium_lab.dom_stories")
  local function selection(id, epoch)
    local story = registry.get(id)
    if not story then error("Hydronium DOM Lab: unknown story " .. tostring(id), 0) end
    local state = lab.state.new(defaults(story), story.controls)
    state.environment, state.setEnvironment = H.signal({ colorSpace = "srgb", vision = "none" })
    return { story = story, state = state, epoch = epoch or 0 }
  end
  local active, setActive = H.createSignal(selection(props.story or registry.stories[1].id))
  local function snapshot()
    local current = active()
    return { story = current.story.id, lab = { args = current.state.args(), playback = current.state.playback() } }
  end
  controller = { snapshot = snapshot }
  function controller.request(message)
    local current = active()
    if message.op == "snapshot" then return snapshot()
    elseif message.op == "open" then setActive(selection(message.story))
    elseif message.op == "environment" then current.state.setEnvironment(message.environment)
    elseif message.op == "args" then current.state.setArgs(message.args)
    elseif message.op == "resetArgs" then current.state.resetArgs()
    elseif message.op == "restart" then
      local next = selection(current.story.id, current.epoch + 1)
      next.state.setArgs(current.state.args()); next.state.setEnvironment(current.state.environment())
      setActive(next)
    else error("Hydronium DOM Lab: unsupported operation " .. tostring(message.op), 0) end
    return snapshot()
  end
  function controller.refresh()
    registry = require("hydronium_lab.dom_stories")
    local current = active()
    local story = registry.get(current.story.id)
    if not story then setActive(selection(registry.stories[1].id))
    else setActive({ story = story, state = current.state, epoch = current.epoch }) end
    return snapshot()
  end
  -- A hot update remounts App: the new instance installs its controller before
  -- the old one's cleanup runs, so only clear the controller if it is still ours.
  local mine = controller
  H.onCleanup(function() if controller == mine then controller = nil end end)
  local function Story(props)
    return function(current) return current.story.render(current.state.args()) end
  end
  return function()
    local current = active()
    return H.h(lab.state.Context.Provider, { value = current.state },
      H.h(Story, { key = current.story.id .. ":" .. current.epoch, story = current.story, state = current.state }))
  end
end
function M.request(message)
  if not controller then error("Hydronium DOM Lab: preview is not mounted", 0) end
  return controller.request(message)
end
function M.refresh()
  if not controller then error("Hydronium DOM Lab: preview is not mounted", 0) end
  return controller.refresh()
end
function M.useEnvironment()
  local state = H.useContext(lab.state.Context)
  if not state or not state.environment then error("DOM Lab environment requires a DOM preview", 2) end
  return state.environment
end
return M
