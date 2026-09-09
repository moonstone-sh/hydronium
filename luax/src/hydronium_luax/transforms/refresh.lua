--[[
  Hydronium LUAX -- automatic HMR refresh-descriptor transform.

  A compile-time AST-to-code pass (NOT a runtime shim) that turns an
  ordinary signal declaration written at the top of a component's setup
  function:

      local count, setCount = hydronium.signal(props.initial or 0)

  into the descriptor-carrying form that hydronium.core.refresh's
  RefreshRegistry can match across a hot swap:

      local count, setCount = scope.refresh_registry:signal(props.initial or 0, {
        kind = "signal", name = "count", block_path = "views.App::Counter.setup"
      })

  WHY: `hydronium.core.component` already gives every ComponentInstance a
  RefreshRegistry that survives :refresh(), and already brackets the
  one-time setup call with :begin_generation()/:finish_generation(). What
  was missing was the descriptor. Without one, a signal is simply
  re-created on every hot swap and its value is lost; with one, the
  registry matches it to the previous generation's signal by
  (kind, name, block_path) and copies the live value forward. Before this
  pass, getting that meant hand-writing the descriptor in every component.

  ---------------------------------------------------------------------
  RECOGNITION RULES -- deliberately narrow. Anything not positively
  recognized is left EXACTLY as written and simply never participates in
  refresh matching, which is the same behavior as before this pass
  existed. A false negative costs one signal's state across a reload; a
  false positive would rewrite code whose runtime shape we guessed wrong.
  We bias hard toward false negatives.

  A statement is rewritten only when ALL of these hold:

   1. It sits at the TOP LEVEL of a recognized component setup function's
      body -- not nested in an `if`/loop/`do` block, and not inside any
      nested closure. This is the "setup once, render many" boundary from
      docs/COMPONENT_MODEL.md: the setup body is what runs exactly once
      per generation, between begin_generation() and finish_generation().
      Code inside the returned render function runs many times per
      generation, so a descriptor there would re-declare the same key on
      every render and is never rewritten. Top-level-only (rather than
      "anywhere that runs once") also keeps the declaration set of a
      component unconditional, which is what makes block_path stable.

   2. The enclosing function looks like a real component setup:
        - it declares a parameter literally named `scope` (this is the
          `scope` the rewrite references -- we never invent a binding, and
          never rewrite when `scope` is merely an ambient upvalue we
          cannot prove points at a ComponentInstance scope), AND
        - its body returns a function (`return function() ... end`),
          which is exactly the shape `component.lua` detects to split
          setup from render.

   3. The statement is `local <a>, <b> = <call>` -- exactly two names and
      exactly one value. The two-name destructure is what makes it a
      signal declaration rather than an arbitrary call; it also gives us
      a real, human-meaningful `name` (the accessor binding).

   4. The call is a recognized signal factory taking exactly one
      argument: a bare `createSignal(x)`, or a member call
      `<obj>.signal(x)` / `<obj>.createSignal(x)` (so `hydronium.signal`,
      `signals.createSignal`, and a user's `local H = require("hydronium")`
      alias all work without hardcoding module names). Zero-argument and
      multi-argument calls are left alone.

  ---------------------------------------------------------------------
  DESCRIPTOR IDENTITY

  `name` is the accessor binding name (`count` for `local count,
  setCount = ...`). Within one setup function the pass tracks names it
  has already issued and suffixes a duplicate with `#2`, `#3`, ... --
  Lua permits shadowing two `local count, setCount` declarations in one
  block, and RefreshRegistry keys on
  (kind .. name .. block_path), so a duplicate key would silently make
  two distinct signals fight over one slot.

  `block_path` is `<module id>::<component identity>.setup`, where the
  module id is the source filename with its extension dropped and
  separators turned into dots (`views/App.luax` -> `views.App`).

  It deliberately contains NO line or column number. block_path must be
  STABLE across exactly the kind of edit that triggers a hot reload --
  if it moved when you added a line above the signal, every reload would
  look like "the old signal disappeared and a new one appeared" and
  state would be silently lost on every save. That is the precise bug
  class this whole feature exists to prevent, so identity is structural,
  never positional.

  The component identity is, in preference order: the name the function
  is bound to (`local function Counter`, `local Counter = function`,
  `function M.Counter`), else `#N` where N is the 1-based index of this
  anonymous setup function among the recognized setup functions of the
  file in source order. The named case is stable under any edit that
  keeps the name. The anonymous case (`return function(props, scope)`,
  the shape hydronium-create's own client counter uses) is stable under
  any edit that does not add or remove another component ahead of it in
  the same file -- the honest limit of identifying something the source
  never named.

  Note that block_path only has to be unique WITHIN one component
  instance: `component.lua` gives each ComponentInstance its own
  RefreshRegistry, so two different modules producing the same
  block_path can never collide in the same registry. The module id is
  there to make the value meaningful and debuggable, not to disambiguate.
--]]

local ast = require("hydronium_luax.ast")

local M = {}

-- Ordered child-field lists. Traversal order must be deterministic and
-- source-ordered, because anonymous setup functions are identified by
-- their index in that order -- a `pairs()` walk would make block_path
-- vary between runs of the same compiler on the same file.
local CHILD_FIELDS = {
  Program = { "body" },
  FunctionExpression = { "params", "body" },
  FunctionDeclaration = { "name", "params", "body" },
  LocalFunctionDeclaration = { "name", "params", "body" },
  LocalStatement = { "names", "values" },
  AssignmentStatement = { "targets", "values" },
  ExpressionStatement = { "expression" },
  ReturnStatement = { "values" },
  DoStatement = { "body" },
  WhileStatement = { "condition", "body" },
  RepeatStatement = { "body", "condition" },
  IfStatement = { "clauses", "else_body" },
  ForNumericStatement = { "var", "start", "stop", "step", "body" },
  ForGenericStatement = { "vars", "iterators", "body" },
  CallExpression = { "callee", "arguments" },
  MethodCallExpression = { "receiver", "arguments" },
  MemberExpression = { "object", "property" },
  BinaryExpression = { "left", "right" },
  UnaryExpression = { "argument" },
  ParenthesizedExpression = { "expression" },
  TableConstructor = { "fields" },
  TableField = { "key", "value" },
  JSXElement = { "opening_element", "children", "closing_element" },
  JSXOpeningElement = { "name", "attributes" },
  JSXClosingElement = { "name" },
  JSXFragment = { "children" },
  JSXAttribute = { "name", "value" },
  JSXSpreadAttribute = { "argument" },
  JSXExpressionContainer = { "expression" },
  JSXMemberExpression = { "object", "property" },
  GotoStatement = {},
  LabelStatement = {},
  Identifier = {},
  StringLiteral = {},
  NumberLiteral = {},
  BooleanLiteral = {},
  NilLiteral = {},
  VarargLiteral = {},
  BreakStatement = {},
  JSXText = {},
  JSXComment = {},
  Comment = {},
}

--- `views/App.luax` -> `views.App`; `./src/client/counter.luax` -> `src.client.counter`.
local function module_id_from_filename(filename)
  local name = tostring(filename or "input.luax")
  name = name:gsub("\\", "/")
  name = name:gsub("^%./", "")
  name = name:gsub("%.%w+$", "")          -- drop extension
  name = name:gsub("^/+", "")             -- absolute paths: drop leading slashes
  name = name:gsub("/", ".")
  if name == "" then name = "input" end
  return name
end

--- Dotted name for `function M.Counter(...)`-style declarations, whose
--- `name` is either an Identifier or a MemberExpression chain.
local function dotted_name(node)
  if type(node) ~= "table" then return nil end
  if node.type == "Identifier" then
    return node.name
  elseif node.type == "MemberExpression" and not node.computed then
    local base = dotted_name(node.object)
    local prop = dotted_name(node.property)
    if base and prop then return base .. "." .. prop end
  end
  return nil
end

local function is_function_node(node)
  return type(node) == "table" and (
    node.type == "FunctionExpression"
    or node.type == "FunctionDeclaration"
    or node.type == "LocalFunctionDeclaration"
  )
end

--- Rule 2a: does this function declare a parameter literally named `scope`?
--- We reference that exact binding in the rewrite, so it must be a real
--- parameter of this function, not something inherited from elsewhere.
local function has_scope_param(fn)
  for _, p in ipairs(fn.params or {}) do
    if type(p) == "table" and p.type == "Identifier" and p.name == "scope" then
      return true
    end
  end
  return false
end

--- Rule 2b: does the body return a function? That is the "setup once,
--- render many" split `component.lua` keys on -- it stores a function
--- result as `renderFn` and calls it for every subsequent render.
local function returns_a_function(fn)
  for _, stmt in ipairs(fn.body or {}) do
    if type(stmt) == "table" and stmt.type == "ReturnStatement" then
      local first = (stmt.values or {})[1]
      if type(first) == "table" then
        if first.type == "FunctionExpression" then
          return true
        end
        -- `return (function() ... end)` -- parenthesized is still the shape.
        if first.type == "ParenthesizedExpression"
          and type(first.expression) == "table"
          and first.expression.type == "FunctionExpression" then
          return true
        end
      end
    end
  end
  return false
end

local function is_component_setup(node)
  return is_function_node(node) and has_scope_param(node) and returns_a_function(node)
end

--- Rule 4: recognized signal-factory callee.
--- Accepts `createSignal(...)`, `<obj>.signal(...)`, `<obj>.createSignal(...)`.
local function is_signal_factory(callee)
  if type(callee) ~= "table" then return false end
  if callee.type == "Identifier" then
    return callee.name == "createSignal"
  end
  if callee.type == "MemberExpression" and not callee.computed then
    local prop = callee.property
    if type(prop) == "table" and prop.type == "Identifier" then
      return prop.name == "signal" or prop.name == "createSignal"
    end
  end
  return false
end

--- Rules 3+4 together: is this top-level statement a rewritable signal
--- declaration? Returns the accessor name and the single initial-value
--- argument, or nil.
local function match_signal_declaration(stmt)
  if type(stmt) ~= "table" or stmt.type ~= "LocalStatement" then return nil end
  if #(stmt.names or {}) ~= 2 then return nil end
  if #(stmt.values or {}) ~= 1 then return nil end

  local accessor = stmt.names[1]
  if type(accessor) ~= "table" or accessor.type ~= "Identifier" then return nil end

  local call = stmt.values[1]
  if type(call) ~= "table" or call.type ~= "CallExpression" then return nil end
  if #(call.arguments or {}) ~= 1 then return nil end
  if not is_signal_factory(call.callee) then return nil end

  return accessor.name, call.arguments[1], call
end

local function descriptor_table(name, block_path, loc)
  return ast.TableConstructor({
    ast.TableField(ast.StringLiteral("kind"), ast.StringLiteral("signal"), loc),
    ast.TableField(ast.StringLiteral("name"), ast.StringLiteral(name), loc),
    ast.TableField(ast.StringLiteral("block_path"), ast.StringLiteral(block_path), loc),
  }, loc)
end

--- Rewrites the recognized top-level declarations of one setup function
--- in place. Only the statements directly in `fn.body` are considered --
--- that IS the once-per-generation boundary (rule 1).
local function rewrite_setup_body(fn, block_path, stats)
  local issued = {}
  for _, stmt in ipairs(fn.body or {}) do
    local name, initial, call = match_signal_declaration(stmt)
    if name then
      -- Guarantee a unique (kind, name, block_path) registry key even
      -- when Lua's shadowing allows the same binding name twice.
      local desc_name = name
      issued[name] = (issued[name] or 0) + 1
      if issued[name] > 1 then
        desc_name = name .. "#" .. tostring(issued[name])
      end

      stmt.values[1] = ast.MethodCallExpression(
        ast.MemberExpression(
          ast.Identifier("scope", call.loc),
          ast.Identifier("refresh_registry", call.loc),
          false,
          call.loc
        ),
        "signal",
        { initial, descriptor_table(desc_name, block_path, call.loc) },
        call.loc
      )

      stats.rewritten = stats.rewritten + 1
      stats.descriptors[#stats.descriptors + 1] = {
        name = desc_name,
        block_path = block_path,
      }
    end
  end
end

--- Deterministic, source-ordered traversal. `name_hint` carries the
--- binding name a function expression is about to be assigned to, so an
--- otherwise-anonymous FunctionExpression can still be identified as
--- `Counter` in `local Counter = function(props, scope)`.
local function walk(node, state, name_hint)
  if type(node) ~= "table" then return end

  if node.type == nil then
    -- A plain array (statement list, argument list, if-clause list) or an
    -- if-clause record; recurse positionally to preserve source order.
    for _, child in ipairs(node) do
      walk(child, state, nil)
    end
    -- If-clause records are `{ condition = ..., body = ... }` with no `type`.
    if node.condition ~= nil then walk(node.condition, state, nil) end
    if node.body ~= nil then walk(node.body, state, nil) end
    return
  end

  if is_component_setup(node) then
    local identity = nil
    if node.type == "FunctionDeclaration" or node.type == "LocalFunctionDeclaration" then
      identity = dotted_name(node.name)
    end
    identity = identity or name_hint
    if not identity then
      state.anon_count = state.anon_count + 1
      identity = "#" .. tostring(state.anon_count)
    end
    local block_path = state.module_id .. "::" .. identity .. ".setup"
    rewrite_setup_body(node, block_path, state.stats)
    state.stats.setups[#state.stats.setups + 1] = block_path
  end

  local fields = CHILD_FIELDS[node.type]
  if fields == nil then
    -- Unknown node type: recurse over array parts only, never guessing
    -- at named fields (an unknown shape must not silently change meaning).
    for _, child in ipairs(node) do
      walk(child, state, nil)
    end
    return
  end

  for _, field in ipairs(fields) do
    local child = node[field]
    if type(child) == "table" then
      -- `local Counter = function(props, scope)` / `M.Counter = function(...)`:
      -- pair the Nth value with the Nth name so the function can be identified.
      if (node.type == "LocalStatement" and field == "values")
        or (node.type == "AssignmentStatement" and field == "values") then
        local targets = node.type == "LocalStatement" and node.names or node.targets
        for i, val in ipairs(child) do
          local hint = nil
          if #child == #(targets or {}) then
            hint = dotted_name((targets or {})[i])
          end
          walk(val, state, hint)
        end
      else
        walk(child, state, nil)
      end
    end
  end
end

--- Apply the pass to a parsed Program in place.
--- @param ast_root table parsed LUAX/Lua Program node
--- @param opts table|nil { filename = "views/App.luax" }
--- @return table ast_root (same table, mutated)
--- @return table stats { rewritten, descriptors, setups }
function M.transform(ast_root, opts)
  opts = opts or {}
  local stats = { rewritten = 0, descriptors = {}, setups = {} }
  if type(ast_root) ~= "table" then return ast_root, stats end

  local state = {
    module_id = module_id_from_filename(opts.filename),
    anon_count = 0,
    stats = stats,
  }
  walk(ast_root, state, nil)
  return ast_root, stats
end

-- Exposed for tests and tooling that want to reason about the boundary
-- without running a full compile.
M.is_component_setup = is_component_setup
M.module_id_from_filename = module_id_from_filename

return M
