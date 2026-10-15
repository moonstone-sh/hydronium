-- Site-facing SSR entrypoint. Plain renderers can import .renderer directly
-- to exclude the optional Meteorite and Vite/manifest integrations.
local renderer = require("hydronium_dom.server.renderer")
local vite_module = require("hydronium_dom.server.vite_module")
local server = {}
for key, value in pairs(renderer) do server[key] = value end

local function options_with_resolver(options)
  local result = {}
  for key, value in pairs(options or {}) do result[key] = value end
  if result.module_resolver == nil then result.module_resolver = vite_module.resolve end
  return result
end

function server.render_to_string(vnode, options)
  return renderer.render_to_string(vnode, options_with_resolver(options))
end
server.renderToString = server.render_to_string

function server.render(vnode, sink, options)
  if type(sink) == "table" and (type(sink.onChunk) == "function" or type(sink.on_chunk) == "function") then
    sink = options_with_resolver(sink)
  end
  return renderer.render(vnode, sink, options_with_resolver(options))
end

function server.render_page(fn)
  return renderer.render_page(function(render)
    return fn(function(vnode, options) return render(vnode, options_with_resolver(options)) end)
  end)
end
server.renderPage = server.render_page

function server.render_to_stream(vnode, options)
  return server.render(vnode, options)
end
server.renderToStream = server.render_to_stream

server.meteorite = setmetatable({}, {
  __index = function(_, key) return require("hydronium_dom.server.meteorite")[key] end,
})
return server
