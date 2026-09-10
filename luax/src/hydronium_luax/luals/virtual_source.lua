--[[
  Hydronium LUAX Virtual Source Lowering for LuaLS
  Complies with:
  - Amendment 2: 1:1 LSP Coordinate Preservation & Virtual Source
    (synthesizes virtual Lua with exact character/whitespace padding so embedded Lua expressions
    retain 1:1 line/column coordinates for diagnostics, autocomplete, hover, and go-to-def)
  - Amendment 3: Virtual Type Injection
    (injects contextual event callback typing e.g. SyntheticMouseEvent<HTMLButtonElement>
    and component prop checking without shifting user code line numbers)
  - Additional Architectural Directive:
    (projects into well-typed ordinary Lua: __luax_intrinsic.<tag>({ ... }) and __luax_component(Comp, { ... })
    so LuaLS natively performs prop diagnostics, autocompletion, and infers callback event parameters)
--]]

local parser_mod = require("hydronium_luax.parser")
local env_mod = require("hydronium_luax.environment")

local virtual_source = {}

local LUA_KEYWORDS = {
  ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true, ["elseif"] = true,
  ["end"] = true, ["false"] = true, ["for"] = true, ["function"] = true, ["goto"] = true,
  ["if"] = true, ["in"] = true, ["local"] = true, ["nil"] = true, ["not"] = true,
  ["or"] = true, ["repeat"] = true, ["return"] = true, ["then"] = true, ["true"] = true,
  ["until"] = true, ["while"] = true,
}

--- Attribute names are free-form JSX/HTML text (kebab-case like
--- `stroke-width`, or a Lua keyword like `for`), but the virtual
--- projection writes them as bare Lua table-constructor keys. Returns a
--- same-length, valid, non-keyword identifier to overwrite the name's
--- own byte range with, or nil if the original name is already fine
--- as-is (the overwhelmingly common case, so most attribute names are
--- never touched at all).
local function sanitize_attr_name(name)
  if name:match("^[_%a][_%w]*$") and not LUA_KEYWORDS[name] then
    return nil
  end
  local sanitized = name:gsub("[^%w_]", "_")
  if sanitized:match("^%d") then
    sanitized = "_" .. sanitized:sub(2)
  end
  if LUA_KEYWORDS[sanitized] then
    sanitized = sanitized:sub(1, -2) .. "_"
  end
  return sanitized
end

--- Replaces characters in a string range [start_idx, end_idx] with replacement string,
--- padding with spaces or comments so the total character count remains identical.
local function pad_to_length(replacement, target_len)
  if #replacement == target_len then
    return replacement
  elseif #replacement < target_len then
    return replacement .. string.rep(" ", target_len - #replacement)
  else
    -- Replacement is longer than target_len; truncate or return replacement
    return replacement
  end
end

--- Synthesizes virtual Lua from LUAX source code.
--- Retains exact 1:1 line and column coordinates for embedded expressions.
--- Projects intrinsic tags to `__luax_intrinsic.<tag>({ ... })` or `_.<tag>({ ... })`
--- Projects component tags to `__luax_component(<Component>, { ... })`
--- @param source string The original .luax source code
--- @param filename string? Optional filename
--- @param options table? Options (e.g. env)
--- @return string virtual_lua Virtual Lua code for LuaLS
--- @return table mappings Coordinate mapping table
function virtual_source.transform(source, filename, options)
  options = options or {}
  local env = options.env or env_mod.get_current()
  filename = filename or "<virtual.luax>"

  -- Parse AST
  local ok, ast_root = pcall(parser_mod.parse, source, filename)
  if not ok then
    -- On parse error (e.g. while user is actively typing in IDE),
    -- return original source or fallback so editor doesn't crash
    return source, {}
  end

  -- Collect all JSX replacements: list of { start_offset, end_offset, replacement }
  local replacements = {}

  local function add_replacement(start_pos, end_pos, text)
    if start_pos and end_pos and start_pos.offset and end_pos.offset then
      table.insert(replacements, {
        start_offset = start_pos.offset,
        end_offset = end_pos.offset,
        start_line = start_pos.line,
        start_col = start_pos.column,
        end_line = end_pos.line,
        end_col = end_pos.column,
        text = text,
      })
    end
  end

  local function walk(node)
    if not node then return end
    local t = node.type

    if t == "Program" then
      for _, stmt in ipairs(node.body) do
        walk(stmt)
      end
    elseif t == "LocalStatement" then
      for _, val in ipairs(node.values) do walk(val) end
    elseif t == "AssignmentStatement" then
      for _, val in ipairs(node.values) do walk(val) end
    elseif t == "ExpressionStatement" then
      walk(node.expression)
    elseif t == "ReturnStatement" then
      for _, val in ipairs(node.values) do walk(val) end
    elseif t == "FunctionDeclaration" or t == "LocalFunctionDeclaration" or t == "FunctionExpression" then
      for _, stmt in ipairs(node.body) do walk(stmt) end
    elseif t == "IfStatement" then
      for _, clause in ipairs(node.clauses) do
        walk(clause.condition)
        for _, s in ipairs(clause.body) do walk(s) end
      end
      if node.else_body then
        for _, s in ipairs(node.else_body) do walk(s) end
      end
    elseif t == "WhileStatement" then
      walk(node.condition)
      for _, s in ipairs(node.body) do walk(s) end
    elseif t == "RepeatStatement" then
      for _, s in ipairs(node.body) do walk(s) end
      walk(node.condition)
    elseif t == "ForNumericStatement" then
      walk(node.start)
      walk(node.stop)
      if node.step then walk(node.step) end
      for _, s in ipairs(node.body) do walk(s) end
    elseif t == "ForGenericStatement" then
      for _, it in ipairs(node.iterators) do walk(it) end
      for _, s in ipairs(node.body) do walk(s) end
    elseif t == "DoStatement" then
      for _, s in ipairs(node.body) do walk(s) end
    elseif t == "BinaryExpression" then
      walk(node.left)
      walk(node.right)
    elseif t == "UnaryExpression" then
      walk(node.argument)
    elseif t == "CallExpression" then
      walk(node.callee)
      for _, arg in ipairs(node.arguments) do walk(arg) end
    elseif t == "MethodCallExpression" then
      walk(node.receiver)
      for _, arg in ipairs(node.arguments) do walk(arg) end
    elseif t == "MemberExpression" then
      walk(node.object)
      if node.computed then walk(node.property) end
    elseif t == "TableConstructor" then
      for _, f in ipairs(node.fields) do
        if f.key then walk(f.key) end
        walk(f.value)
      end
    elseif t == "ParenthesizedExpression" then
      walk(node.expression)
    elseif t == "JSXElement" then
      local opening = node.opening_element
      local name_node = opening.name
      local is_intrinsic = false
      local tag_name = ""

      if name_node.type == "Identifier" then
        tag_name = name_node.name
        is_intrinsic = env:is_intrinsic(tag_name)
      elseif name_node.type == "JSXMemberExpression" then
        tag_name = "Component"
      end

      -- Walk attribute expressions
      for _, attr in ipairs(opening.attributes) do
        if attr.type == "JSXSpreadAttribute" then
          walk(attr.argument)
        elseif attr.type == "JSXAttribute" and attr.value.type == "JSXExpressionContainer" then
          walk(attr.value.expression)
        end
      end

      -- Walk children
      for _, child in ipairs(node.children or {}) do
        if child.type == "JSXExpressionContainer" then
          walk(child.expression)
        elseif child.type == "JSXElement" or child.type == "JSXFragment" then
          walk(child)
        end
      end

    elseif t == "JSXFragment" then
      for _, child in ipairs(node.children or {}) do
        if child.type == "JSXExpressionContainer" then
          walk(child.expression)
        elseif child.type == "JSXElement" or child.type == "JSXFragment" then
          walk(child)
        end
      end
    end
  end

  walk(ast_root)

  -- Function to project a single JSXElement into virtual code
  -- Preserves line count and pads characters to match source offsets
  local function transform_element(node)
    local opening = node.opening_element
    local is_self_closing = opening.self_closing
    local name_node = opening.name
    local is_intrinsic = false
    local tag_str = ""

    if name_node.type == "Identifier" then
      tag_str = name_node.name
      is_intrinsic = env:is_intrinsic(tag_str)
    elseif name_node.type == "JSXMemberExpression" then
      is_intrinsic = false
      local function get_name(m)
        if m.type == "Identifier" then return m.name end
        return get_name(m.object) .. "." .. m.property.name
      end
      tag_str = get_name(name_node)
    end

    -- Construct typed call prefix:
    -- For intrinsic: __luax_intrinsic.button({ ... }) or _.button({ ... })
    -- For component: __luax_component(MyComponent, { ... })
    local target_prefix
    if is_intrinsic then
      target_prefix = "__luax_intrinsic." .. tag_str .. "({"
    else
      target_prefix = "__luax_component(" .. tag_str .. ", {"
    end

    return target_prefix
  end

  -- Line-by-line 1:1 character-padding virtual source synthesizer:
  -- Replaces JSX markup tokens while leaving user expressions untouched at the exact byte offsets!
  local result_chars = {}
  local src_len = #source
  local i = 1

  -- Track replacements in source
  -- Transform AST by replacing JSX delimiters with whitespace / typed wrappers
  local function build_virtual()
    local buffer = {}
    local line_num = 1
    local col_num = 1

    -- We perform a specialized source rewrite that masks JSX tags with valid Lua tokens
    -- of EXACT matching character length, keeping embedded expressions untouched.
    local bytes = {}
    for idx = 1, #source do
      bytes[idx] = source:sub(idx, idx)
    end

    -- Helper to replace range in bytes array with string, strictly preserving newlines.
    -- `write_idx` (the cursor into `new_str`) only advances on an actual
    -- write, so a newline inside the range (e.g. a multi-line opening
    -- tag like `<input\n  type="text"\n  .../>`) is skipped without
    -- eating a character of `new_str` -- previously it advanced in lockstep
    -- with `pos`, so every newline silently dropped one character of the
    -- replacement (frequently the opening `{`), corrupting the emitted
    -- virtual Lua for any multi-line tag.
    local function overwrite_range(start_idx, end_idx, new_str)
      local write_idx = 1
      for pos = start_idx, end_idx do
        if pos <= #bytes and bytes[pos] ~= "\n" then
          local ch = new_str:sub(write_idx, write_idx)
          if ch == "" then ch = " " end
          bytes[pos] = ch
          write_idx = write_idx + 1
        end
      end
    end

    -- Collect all JSX elements and fragments from AST
    local jsx_nodes = {}
    local function collect_jsx(n)
      if not n then return end
      if n.type == "JSXElement" or n.type == "JSXFragment" then
        table.insert(jsx_nodes, n)
      end

      -- IfStatement is special-cased (matching the `walk()` traversal
      -- above): `node.clauses` is an array of {condition, body} wrapper
      -- objects, not an array of typed AST nodes -- the generic fallback
      -- below only recurses into an array element when it has its own
      -- `.type` field, so a clause wrapper (which has none) is invisible
      -- to it, and anything nested inside an `if`/`elseif` branch --
      -- including a bare `return <JSX>` -- was silently never collected,
      -- never lowered, and left as raw JSX text for LuaLS's real Lua
      -- parser to choke on (verified: the real compiler's AST for such a
      -- `return` is correct and compiles fine -- this was purely a gap
      -- in this walker, not a parser bug). `else_body` doesn't need the
      -- same treatment -- it's already a plain array of typed statements.
      if n.type == "IfStatement" then
        for _, clause in ipairs(n.clauses or {}) do
          collect_jsx(clause.condition)
          for _, s in ipairs(clause.body or {}) do
            collect_jsx(s)
          end
        end
        if n.else_body then
          for _, s in ipairs(n.else_body) do
            collect_jsx(s)
          end
        end
        return
      end

      -- Recurse into children / body
      for k, v in pairs(n) do
        if type(v) == "table" and k ~= "loc" then
          if v.type then
            collect_jsx(v)
          else
            for _, child in ipairs(v) do
              if type(child) == "table" and child.type then
                collect_jsx(child)
              end
            end
          end
        end
      end
    end

    collect_jsx(ast_root)

    -- Process each JSX node (leaf first to avoid offset collisions)
    for _, node in ipairs(jsx_nodes) do
      if node.type == "JSXElement" then
        local opening = node.opening_element
        local is_self = opening.self_closing
        local is_intrinsic = false
        local tag_str = ""

        if opening.name.type == "Identifier" then
          tag_str = opening.name.name
          is_intrinsic = env:is_intrinsic(tag_str)
        elseif opening.name.type == "JSXMemberExpression" then
          local function get_name(m)
            if m.type == "Identifier" then return m.name end
            return get_name(m.object) .. "." .. m.property.name
          end
          tag_str = get_name(opening.name)
        else
          tag_str = "Comp"
        end

        local num_attrs = #opening.attributes
        local has_non_comment_children = false
        for _, child in ipairs(node.children or {}) do
          if child.type ~= "JSXComment" then
            if child.type == "JSXText" then
              if child.value and child.value:match("%S") then
                has_non_comment_children = true
                break
              end
            else
              has_non_comment_children = true
              break
            end
          end
        end

        local open_start = opening.loc and opening.loc.start and opening.loc.start.offset
        local open_end = opening.loc and opening.loc["end"] and opening.loc["end"].offset

        if open_start then
          if num_attrs > 0 then
            -- Replace '<tag ' with ' tag{' (maintains exact character count to first attribute)
            local first_attr_start = opening.attributes[1].loc.start.offset
            local replace_end = first_attr_start - 1
            local target_len = replace_end - open_start + 1
            local prefix = " " .. tag_str .. "{"
            overwrite_range(open_start, replace_end, pad_to_length(prefix, target_len))
          else
            -- No attributes
            if is_self then
              local target_len = open_end - open_start + 1
              local prefix
              if target_len >= #tag_str + 4 then
                prefix = " " .. tag_str .. "{ }"
              else
                prefix = " " .. tag_str .. "{}"
              end
              overwrite_range(open_start, open_end, pad_to_length(prefix, target_len))
            else
              local target_len = open_end - open_start + 1
              local prefix = " " .. tag_str .. "{"
              overwrite_range(open_start, open_end, pad_to_length(prefix, target_len))
            end
          end
        end

        -- Attribute replacements: name={expr} -> name = (expr)
        for idx, attr in ipairs(opening.attributes) do
          if attr.type == "JSXAttribute" and attr.loc and attr.loc.start then
            local sanitized = sanitize_attr_name(attr.name)
            if sanitized then
              local name_start = attr.loc.start.offset
              for k = 1, #sanitized do
                bytes[name_start + k - 1] = sanitized:sub(k, k)
              end
            end
          end

          if attr.type == "JSXAttribute" and attr.value.type == "JSXExpressionContainer" then
            if attr.value.loc and attr.value.loc.start and attr.value.loc["end"] then
              bytes[attr.value.loc.start.offset] = "("
              bytes[attr.value.loc["end"].offset] = ")"
            end
          elseif attr.type == "JSXSpreadAttribute" then
            if attr.loc and attr.loc.start and attr.loc["end"] and attr.argument and attr.argument.loc then
              local s_start = attr.loc.start.offset
              local s_end = attr.loc["end"].offset
              local arg_start = attr.argument.loc.start.offset
              local arg_end = attr.argument.loc["end"].offset
              -- Mask '{...' before argument with ',   ' (or '    ' if first)
              local before_len = arg_start - s_start
              local before_str = (idx > 1 and "," or " ") .. string.rep(" ", math.max(0, before_len - 1))
              overwrite_range(s_start, arg_start - 1, before_str)
              -- Mask '}' after argument
              if s_end > arg_end then
                local after_len = s_end - arg_end
                local after_str = (idx < num_attrs and "," or " ") .. string.rep(" ", math.max(0, after_len - 1))
                overwrite_range(arg_end + 1, s_end, after_str)
              end
            end
          end

          -- Insert comma field separator between attributes. Scans for
          -- the first non-newline byte in the gap rather than always
          -- writing to curr_end + 1 -- a multi-line attribute list (each
          -- attribute on its own line, extremely common real-world
          -- formatting) has that exact byte be the preserved "\n" itself,
          -- and unconditionally overwriting it collapsed the entire
          -- attribute list onto one virtual line, corrupting every
          -- subsequent line's 1:1 coordinate mapping for the rest of the
          -- element.
          if idx < num_attrs and attr.type ~= "JSXSpreadAttribute" then
            local next_attr = opening.attributes[idx + 1]
            if next_attr and next_attr.type ~= "JSXSpreadAttribute" then
              local curr_end = attr.loc and attr.loc["end"] and attr.loc["end"].offset
              local next_start = next_attr.loc and next_attr.loc.start and next_attr.loc.start.offset
              if curr_end and next_start and next_start > curr_end then
                for p = curr_end + 1, next_start - 1 do
                  if bytes[p] ~= "\n" then
                    bytes[p] = ","
                    break
                  end
                end
              end
            end
          end
        end

        -- Replace self-closing '/>' or closing '>'
        if is_self then
          if num_attrs > 0 and open_end then
            if bytes[open_end - 1] == "/" and bytes[open_end] == ">" then
              bytes[open_end - 1] = " "
              bytes[open_end] = "}"
            end
          end
        else
          -- Closing '>' of opening tag
          if num_attrs > 0 and open_end then
            if bytes[open_end] == ">" then
              if has_non_comment_children then
                bytes[open_end] = ","
              else
                bytes[open_end] = " "
              end
            end
          end

          -- Replace closing tag </tag> with `}` followed by a line
          -- comment filling the rest of the span (e.g. </d.button> ->
          -- }-------), but ONLY when nothing else follows on the same
          -- physical line -- a line comment runs to the next `\n`
          -- regardless of what real code sits after it, so using one
          -- when a closing tag is immediately followed by more markup
          -- on the same line (e.g. `</code></pre>`, or a sibling
          -- separator comma) would silently swallow that content,
          -- corrupting the parse (caught by the sweep in commit
          -- b434c73's follow-up: examples/showcase/ErrorBoundary.luax's
          -- `</code></pre>` and a sibling comma in
          -- examples/meteorite_ssr/views/App.luax both broke this way
          -- on the first attempt). When a closing tag IS the last thing
          -- on its line (the common case -- most real markup puts one
          -- closing tag per line), plain spaces (the prior behavior)
          -- become real trailing whitespace in the virtual document:
          -- harmless to parsing, but LuaLS's own "Line with trailing
          -- space" diagnostic fires on every one (confirmed live:
          -- 37/37 remaining diagnostics on that same App.luax were
          -- exactly this, once the real syntax errors were fixed and
          -- stopped burying it). The shortest possible closing tag,
          -- `</a>`, is 4 bytes -- enough for `}` + `--` + 1 more `-`.
          if node.closing_element and node.closing_element.loc then
            local c_start = node.closing_element.loc.start.offset
            local c_end = node.closing_element.loc["end"].offset
            if c_start and c_end then
              local c_len = c_end - c_start + 1
              local is_last_on_line = true
              for p = c_end + 1, #source do
                local ch = source:sub(p, p)
                if ch == "\n" then
                  break
                elseif ch ~= " " and ch ~= "\t" and ch ~= "\r" then
                  is_last_on_line = false
                  break
                end
              end

              local padding
              if c_len <= 1 then
                padding = "}"
              elseif c_len == 2 or not is_last_on_line then
                padding = pad_to_length("}", c_len)
              else
                padding = "}--" .. string.rep("-", c_len - 3)
              end
              overwrite_range(c_start, c_end, padding)
            end
          end
        end

        -- Children: safely project text children into valid Lua table expressions
        for _, child in ipairs(node.children or {}) do
          if child.type == "JSXText" and child.loc and child.loc.start and child.loc["end"] then
            local t_start = child.loc.start.offset
            local t_end = child.loc["end"].offset
            if t_end >= t_start then
              -- Process line by line within [t_start, t_end]. A single
              -- JSXText node that spans multiple physical lines becomes
              -- one separate quoted-string (or lone "0") table entry per
              -- line, since a plain "..." Lua string can't itself
              -- contain a literal newline -- but that means these
              -- per-line segments are new SIBLING table entries that
              -- also need a "," between them, same as sibling JSX
              -- children do. `prev_seg_end` tracks the last byte of the
              -- previous line's segment (across blank lines too, so a
              -- blank line in between doesn't lose the anchor) so a
              -- comma can be stolen from whatever whitespace exists
              -- between it and the next segment.
              local line_start = t_start
              local prev_seg_end = nil
              while line_start <= t_end do
                local line_end = line_start
                while line_end <= t_end and bytes[line_end] ~= "\n" do
                  line_end = line_end + 1
                end
                -- Within [line_start, line_end - 1], find first and last non-space char
                local seg_end = math.min(line_end - 1, t_end)
                local first_non_ws = nil
                local last_non_ws = nil
                for p = line_start, seg_end do
                  local b = bytes[p]
                  if b ~= " " and b ~= "\t" and b ~= "\r" then
                    if not first_non_ws then first_non_ws = p end
                    last_non_ws = p
                  end
                end

                if first_non_ws and last_non_ws then
                  local seg_start_pos = first_non_ws
                  if first_non_ws == last_non_ws then
                    bytes[first_non_ws] = "0"
                  else
                    bytes[first_non_ws] = '"'
                    bytes[last_non_ws] = '"'
                    for p = first_non_ws + 1, last_non_ws - 1 do
                      bytes[p] = " "
                    end
                  end

                  if prev_seg_end then
                    for p = prev_seg_end + 1, seg_start_pos - 1 do
                      if bytes[p] == " " then
                        bytes[p] = ","
                        break
                      end
                    end
                  end
                  prev_seg_end = last_non_ws
                end

                line_start = line_end + 1
              end
            end
          elseif child.type == "JSXComment" and child.loc and child.loc.start and child.loc["end"] then
            local t_start = child.loc.start.offset
            local t_end = child.loc["end"].offset
            for idx = t_start, t_end do
              if bytes[idx] ~= "\n" then bytes[idx] = " " end
            end
          elseif child.type == "JSXExpressionContainer" and child.loc and child.loc.start and child.loc["end"] then
            -- A bare `{expr}` child (as opposed to an attribute value,
            -- handled separately above) needs no parenthesizing -- a
            -- bare expression is already a valid positional table
            -- entry. Blank its `{`/`}` delimiters to plain spaces,
            -- leaving `expr` untouched at its exact offsets; blanking to
            -- spaces (rather than leaving `{`/`}` in place) also makes
            -- these positions valid steal-a-separator candidates for the
            -- sibling-comma pass below when this child sits directly
            -- against a neighbor with no gap (e.g. `v{pkg.version}`).
            local e_start = child.loc.start.offset
            local e_end = child.loc["end"].offset
            -- Guard against the same trailing-whitespace artifact fixed
            -- for closing tags above: a solo `{expr}` child (e.g.
            -- `<main>{props.children}</main>`) as the only content on
            -- its line has this `}` as the very last non-whitespace
            -- byte -- blanking it to a space then reads as real
            -- trailing whitespace to LuaLS. A lone `}` can't be
            -- comment-padded (a `--` comment needs 2 bytes); leaving
            -- BOTH original delimiters in place instead is simplest and
            -- still valid Lua (a single-value nested table is a legal
            -- positional table entry, same as a bare value). Blanking
            -- only the closing `}` while still blanking the opening `{`
            -- (an earlier version of this fix) removes one brace of the
            -- pair but not the other, undercounting closing braces for
            -- the *enclosing* call by one -- caught by the sweep
            -- immediately: every file with a solo trailing `{expr}`
            -- child stopped parsing.
            local last_on_line = true
            for p = e_end + 1, #source do
              local ch = source:sub(p, p)
              if ch == "\n" then
                break
              elseif ch ~= " " and ch ~= "\t" and ch ~= "\r" then
                last_on_line = false
                break
              end
            end
            if not last_on_line then
              if bytes[e_start] == "{" then bytes[e_start] = " " end
              if bytes[e_end] == "}" then bytes[e_end] = " " end
            end
          end
        end

      elseif node.type == "JSXFragment" then
        -- <> -> {
        local f_start = node.loc.start.offset
        if bytes[f_start] == "<" and bytes[f_start + 1] == ">" then
          bytes[f_start] = "{"
          bytes[f_start + 1] = " "
        end
        -- </> -> }
        local f_end = node.loc["end"].offset
        if bytes[f_end - 2] == "<" and bytes[f_end - 1] == "/" and bytes[f_end] == ">" then
          bytes[f_end - 2] = "}"
          bytes[f_end - 1] = " "
          bytes[f_end] = " "
        end
      end
    end

    -- JSX has no comma-separated child list, but the virtual Lua table
    -- constructor each element becomes (`tag{ ...attrs..., child1, child2 }`)
    -- requires one. Without this, e.g. `<a><b/><c/></a>` (2 sibling
    -- children, no separator in the source) lowers to invalid Lua
    -- (`b{} c{}` with no `,`/`;` between them), which does not fail loudly --
    -- LuaLS's own Lua parser recovers by folding the malformed span into one
    -- oversized token/reference, which silently corrupts multi-line
    -- rename/reference results (see docs/LUAX_DX_CURRENT_STATE.md). Insert a
    -- "," into the first available non-newline byte of the gap between each
    -- pair of consecutive significant children (that gap is ordinary
    -- whitespace between tags in real-world formatted code, so this rarely
    -- needs to consume anything meaningful; if no such byte exists -- e.g.
    -- `<a/><b/>` with zero whitespace between them -- the gap is left as-is
    -- and the virtual document remains invalid Lua for that one edge case).
    local function significant_children(children)
      local sig = {}
      for _, c in ipairs(children or {}) do
        if c.type == "JSXComment" then
          -- skip: comments are blanked out, not a value in the child list
        elseif c.type == "JSXText" then
          if c.value and c.value:match("%S") then
            table.insert(sig, c)
          end
        else
          table.insert(sig, c)
        end
      end
      return sig
    end

    local function insert_separator(gap_start, gap_end)
      for p = gap_start, gap_end do
        if bytes[p] and bytes[p] ~= "\n" then
          bytes[p] = ","
          return
        end
      end
    end

    for _, node in ipairs(jsx_nodes) do
      local children = (node.type == "JSXElement" or node.type == "JSXFragment") and node.children
      if children then
        local sig = significant_children(children)
        for i = 1, #sig - 1 do
          local a, b = sig[i], sig[i + 1]
          local a_end = a.loc and a.loc["end"] and a.loc["end"].offset
          local b_start = b.loc and b.loc.start and b.loc.start.offset
          if a_end and b_start then
            if b_start > a_end + 1 then
              insert_separator(a_end + 1, b_start - 1)
            else
              -- No gap between the two children's own loc spans -- the
              -- common case for inline text mixed with inline elements
              -- (e.g. `text <code>x</code> more text`), since a JSXText
              -- node's span already consumes its own surrounding
              -- whitespace, leaving no byte "between" the two spans to
              -- claim. Steal a literal space from inside one of the two
              -- children's own spans instead: `a`'s last byte is either
              -- a text node's untouched trailing whitespace or a closing
              -- tag's padding space (both plain " ", never "\n" or a
              -- quote written by the text-quoting pass above); failing
              -- that, `b`'s first byte is a JSXText node's own leading
              -- whitespace, OR -- if `b` is itself an element -- always
              -- a synthesized leading space, since every element-open
              -- replacement is " " .. tag .. "{" overwriting the
              -- original `<` (see the opening-tag overwrites above) --
              -- so this also resolves the previously-uncovered
              -- zero-whitespace-anywhere case (e.g. `<a/><b/>`).
              if bytes[a_end] == " " then
                bytes[a_end] = ","
              elseif bytes[b_start] == " " then
                bytes[b_start] = ","
              end
            end
          end
        end
      end
    end

    return table.concat(bytes)
  end

  local virtual_code = build_virtual()

  return virtual_code, {
    to_virtual = function(line, col) return line, col end,
    to_source = function(line, col) return line, col end,
  }
end

return virtual_source
