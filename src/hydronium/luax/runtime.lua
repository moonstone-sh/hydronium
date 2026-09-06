--[[
  Hydronium LUAX Runtime ABI
  Complies with Amendment 4:
  - __luax.spread(...) runtime merge helper: left-to-right evaluation where later keys overwrite earlier keys
  - Lowering helper functions for JSX elements and fragments
--]]

local runtime = {}

--- Merges property tables left-to-right.
--- Later keys overwrite earlier keys.
--- Gracefully skips nil, boolean false, or non-table arguments (e.g. from conditional guards).
--- @param ... table|nil Tables to merge
--- @return table Merged table
function runtime.spread(...)
  local result = {}
  local argc = select("#", ...)

  for i = 1, argc do
    local tbl = select(i, ...)
    if type(tbl) == "table" then
      for k, v in pairs(tbl) do
        result[k] = v
      end
    end
  end

  return result
end

--- Lazy-loaded hydronium reference
local hydronium_lib = nil

local function get_hydronium()
  if not hydronium_lib then
    local ok, lib = pcall(require, "hydronium")
    if ok then
      hydronium_lib = lib
    else
      -- Fallback minimal virtual node constructor if hydronium not in package.path
      hydronium_lib = {
        createElement = function(tag, props, ...)
          local children = {}
          local count = select("#", ...)
          for i = 1, count do
            table.insert(children, select(i, ...))
          end
          return {
            _typeof = "HYDRONIUM_VNODE",
            tag = tag,
            props = props or {},
            children = children,
          }
        end,
        Fragment = "__HYDRONIUM_FRAGMENT__",
      }
    end
  end
  return hydronium_lib
end

--- Injects or overrides the underlying UI library implementation.
function runtime.set_hydronium(lib)
  hydronium_lib = lib
end

--- Element creation helper invoked by compiled LUAX code.
--- @param tag string|table|function Component or intrinsic tag
--- @param props table? Normalized or spread props table
--- @param ... any Varargs children
function runtime.element(tag, props, ...)
  local hydro = get_hydronium()
  return hydro.createElement(tag, props, ...)
end

--- Fragment creation helper invoked by compiled LUAX code.
--- @param props table? Fragment props (typically nil)
--- @param ... any Varargs children
function runtime.fragment(props, ...)
  local hydro = get_hydronium()
  return hydro.createElement(hydro.Fragment, props, ...)
end

-- Also expose as global __luax for runtime compatibility when required
if _G and not _G.__luax then
  _G.__luax = runtime
end

return runtime
