--- Normalizes the small synchronous server sink protocol.
--- A sink is either `fun(chunk)` or `{ write = fun(self, chunk), flush?,
--- close? }`. Table callbacks always receive the sink as their first argument.
--- Use a function sink for a chunk-only callback; no arity inference is done.
---@class HydroniumServerSink
---@field write fun(self: HydroniumServerSink, chunk: string)
---@field flush? fun(self: HydroniumServerSink)
---@field close? fun(self: HydroniumServerSink)
local M = {}

local function call_member(sink, method)
  if type(sink[method]) == 'function' then
    return sink[method](sink)
  end
end

---@param sink fun(chunk: string)|HydroniumServerSink
function M.normalize(sink)
  if type(sink) == 'function' then
    return {
      write = sink,
      flush = function() end,
      close = function() end,
    }
  end
  if type(sink) ~= 'table' or type(sink.write) ~= 'function' then
    error('server.render: sink must be a function or provide a write method', 3)
  end

  local write = sink.write

  return {
    write = function(chunk)
      return write(sink, chunk)
    end,
    flush = function() return call_member(sink, 'flush') end,
    close = function() return call_member(sink, 'close') end,
  }
end

return M
