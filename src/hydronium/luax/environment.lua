--[[
  Hydronium LUAX Schema Provider / Environment Protocol
  Complies with Amendment 5:
  - Zero hardcoded HTML tags or module names in hydronium.luax
  - hydronium.luax.Environment<I> protocol where imported host packages provide typed intrinsics
--]]

local environment = {}

local Environment = {}
Environment.__index = Environment

local registered_environments = {}
local current_environment = nil

--- Creates and registers a new typed host environment.
--- @param spec table Configuration schema for the environment:
---   - name: string (e.g. "dom", "love2d", "terminal", "universal")
---   - factory: string (e.g. "__luax.element" or "hydronium.createElement")
---   - fragment: string (e.g. "__luax.fragment" or "hydronium.Fragment")
---   - spread: string (e.g. "__luax.spread")
---   - intrinsics: table|function Set of allowed intrinsic tag names or validation predicate
---   - is_intrinsic: function(tag_name): boolean
---   - component_wrapper: string? (e.g. "__luax_component")
---   - metadata: table?
function environment.define(spec)
  if type(spec) ~= "table" then
    error("Environment.define expects a table specification", 2)
  end
  if type(spec.name) ~= "string" or #spec.name == 0 then
    error("Environment.define requires a non-empty string 'name'", 2)
  end

  local env = setmetatable({
    name = spec.name,
    factory = spec.factory or "__luax.element",
    fragment = spec.fragment or "__luax.fragment",
    spread = spec.spread or "__luax.spread",
    component_wrapper = spec.component_wrapper or "__luax_component",
    intrinsics = spec.intrinsics or {},
    metadata = spec.metadata or {},
  }, Environment)

  if type(spec.is_intrinsic) == "function" then
    env._is_intrinsic_fn = spec.is_intrinsic
  elseif type(spec.intrinsics) == "table" and next(spec.intrinsics) ~= nil then
    env._is_intrinsic_fn = function(tag)
      return spec.intrinsics[tag] ~= nil
    end
  else
    -- Default heuristic when no explicit intrinsics table provided:
    -- Lowercase or hyphenated tags are intrinsic tags; Capitalized are components.
    env._is_intrinsic_fn = function(tag)
      if type(tag) ~= "string" then return false end
      if tag:find("%.") then return false end -- Dotted paths are components (e.g. UI.Button)
      if tag:find("%-") then return true end
      local first_char = tag:sub(1, 1)
      return first_char:match("[a-z]") ~= nil
    end
  end

  registered_environments[spec.name] = env
  if not current_environment then
    current_environment = env
  end

  return env
end

--- Returns whether a given tag name is an intrinsic element in this environment.
function Environment:is_intrinsic(tag_name)
  return self._is_intrinsic_fn(tag_name)
end

--- Gets a registered environment by name.
function environment.get(name)
  return registered_environments[name]
end

--- Sets the globally active environment.
function environment.set_current(env_or_name)
  if type(env_or_name) == "string" then
    local found = registered_environments[env_or_name]
    if not found then
      error("Environment not found: " .. env_or_name, 2)
    end
    current_environment = found
  elseif type(env_or_name) == "table" and getmetatable(env_or_name) == Environment then
    current_environment = env_or_name
  else
    error("Invalid environment passed to set_current", 2)
  end
  return current_environment
end

-- Register default universal environment on module initialization
environment.define({
  name = "universal",
  factory = "__luax.element",
  fragment = "__luax.fragment",
  spread = "__luax.spread",
  component_wrapper = "__luax_component",
})

--- Gets the active environment.
function environment.get_current()
  return current_environment or environment.get("universal")
end

environment.Environment = Environment
return environment
