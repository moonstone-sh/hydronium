-- Boots lua-language-server from the vfs (shim.lua must have run) without
-- stdio: messages come in through LUALS.receive(json) and leave through
-- LUALS.emit(json), set by the host; LUALS.step(budget_ms) runs the event
-- loop until it is idle or the budget is spent.
local root = "/luals"
package.path = root .. "/script/?.lua;" .. root .. "/script/?/init.lua"

local fs = require "bee.filesystem"
local util = require "utility"
require "config.env"

ROOT = fs.path(root)
LOGPATH = root .. "/log"
METAPATH = root .. "/meta"
LOGLEVEL = LOGLEVEL or "warn"
util.enableCloseFunction()
util.enableFormatString()

log = require "log"
log.init(ROOT, fs.path(LOGPATH) / "service.log")
log.level = LOGLEVEL
-- Logs go to the host console instead of a file nobody reads.
local logRaw = log.raw
function log.raw(thd, level, msg, ...)
  if LUALS and LUALS.log and (level == "error" or level == "warn" or LOGLEVEL == "trace" or LOGLEVEL == "info") then
    LUALS.log(level, msg)
  end
  return logRaw(thd, level, msg, ...)
end

require "tracy"
local await = require "await"
local pub = require "pub"
-- The worker tasks (loadFile, compile, ...) live in brave/work.lua, which only
-- worker threads load; here they run in place (shim.lua).
require "brave"
local proto = require "proto"
local json = require "json"
local timer = require "timer"
local service = require "service"

proto.mode = "host"
function proto.send(data)
  LUALS.emit(json.encode(data))
end

await.setErrorHandle(log.error)
service.report()
require "provider"

LUALS = LUALS or {}
function LUALS.receive(text)
  local message = json.decode(text)
  pub.ability.proto(message)
end
local now = require("bee.time").monotonic
function LUALS.step(budget)
  local start = now()
  local worked = false
  repeat
    timer.update()
    local did = await.step()
    worked = worked or did
  until not did or now() - start > (budget or 50)
  return worked
end
return LUALS
