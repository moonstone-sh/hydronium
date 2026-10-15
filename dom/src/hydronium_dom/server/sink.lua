--- Normalizes the small synchronous server sink protocol.
--- A sink is either `fun(chunk)` or `{ write = fun(self, chunk), flush?,
--- close? }`. A one-argument table write function remains supported for
--- compatibility; new integrations should use the method form.
local compat = require("hydronium.compat")

local M = {}

local function call_member(sink, method)
  if type(sink[method]) == 'function' then
    return sink[method](sink)
  end
end

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
  local nparams, isvararg = compat.function_arity(write)
  local takes_chunk_only = nparams == 1 and not isvararg

  return {
    write = function(chunk)
      if takes_chunk_only then
        return write(chunk)
      end
      return write(sink, chunk)
    end,
    flush = function() return call_member(sink, 'flush') end,
    close = function() return call_member(sink, 'close') end,
  }
end

return M
