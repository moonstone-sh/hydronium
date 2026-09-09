--[[
  hydronium_dom.css -- real scoped CSS for .luax components. Zero new
  .luax syntax (see docs/LUAX_BALLAD_CSS_ASSETS_PLAN.md section 2.1 for
  why: this file's own lexer has a fixed keyword table and the LuaLS
  virtual-source rewriter needs byte-exact-or-shorter valid-Lua
  replacements for anything new, which a real `import` statement can't
  satisfy). Component authors write:

    local css = require("hydronium_dom.css")
    local s = css.sheet("src/views/Header.css")
    ... <d.header class={s.showcase_header}> ...

  HOW SCOPING WORKS WITH NO RUNTIME FILE I/O AND NO BUILD-TIME MANIFEST:
  `sheet(path)` never reads the .css file at all -- `scope_class(path,
  class_name)` is a PURE function of its two string arguments, so a
  scoped class name can be computed identically at runtime (here, via
  `sheet(path).some_class`) and at build time (by
  hydronium_ballad.plugins.style, which parses the REAL .css file and
  rewrites its selectors using this exact same function) with zero
  coordination beyond both sides agreeing on the formula in this one
  file. `sheet(path)` returns a metatable-backed proxy: indexing it with
  ANY key (dot or bracket) computes and returns that key's scoped class
  name on demand.

  Key-name convenience: `s.nav_link` and `s["nav-link"]` both resolve to
  the SAME scoped name (indexing always converts "_" -> "-" before
  hashing, since Lua identifiers can't contain "-" at all, so dot-access
  to a hyphenated real class name needs this to be usable). Stated
  limitation: a stylesheet that legitimately has BOTH `.foo_bar` and
  `.foo-bar` as distinct classes cannot be disambiguated via dot-access
  (`s.foo_bar` resolves to the hyphenated one) -- use bracket access with
  the literal name in that rare case; this is a real, accepted v1
  tradeoff, not an oversight.
--]]

local M = {}

-- A DJB2-style polynomial string hash, NOT a bitwise FNV-1a, DELIBERATELY:
-- this file is required both server-side (LuaJIT/PUC 5.1-5.4) and
-- client-side (real Lua 5.4 inside wasmoon, see
-- docs/HYDRONIUM_CLIENT_BUNDLER_MINIFIER_PLAN.md section 1.1's finding).
-- Lua 5.4 has NATIVE bitwise-operator syntax (`~`, `<<`, ...) that is a
-- SYNTAX ERROR on 5.1/5.2/LuaJIT, and LuaJIT's `bit` library doesn't
-- exist on plain PUC 5.4 -- there is no single bitwise-XOR expression
-- this codebase's whole Lua 5.1-5.4 compatibility matrix (see
-- docs/HYDRONIUM_CURRENT_STATE_AUDIT.md) can parse everywhere at once.
-- A pure +/*/% arithmetic hash sidesteps the whole problem. Collision
-- resistance requirements here are "good enough to avoid two different
-- real class names in the same file colliding," not cryptographic.
local function scope_hash(str)
  local hash = 5381
  for i = 1, #str do
    hash = (hash * 33 + str:byte(i)) % 4294967296
  end
  return string.format("%08x", hash)
end

--- @param css_path string Project-relative path to the .css file, e.g. "src/views/Header.css".
--- @param class_name string The REAL, hyphenated CSS class name (not underscore-converted).
--- @return string
function M.scope_class(css_path, class_name)
  local basename = css_path:match("([^/\\]+)%.css$") or css_path
  local underscored = (class_name:gsub("%-", "_"))
  local hash8 = scope_hash(css_path .. "\0" .. class_name):sub(1, 8)
  return basename .. "_" .. underscored .. "_" .. hash8
end

local sheet_metatable = {
  __index = function(self, key)
    local class_name = (key:gsub("_", "-"))
    return M.scope_class(self.__css_path, class_name)
  end,
  __newindex = function()
    error("hydronium_dom.css: the table returned by css.sheet(...) is read-only", 2)
  end,
}

--- @param css_path string Project-relative path to a real .css file (e.g. "src/views/Header.css") -- MUST match exactly what hydronium_ballad.plugins.style sees for that same file, or the scoped names won't agree.
--- @return table<string, string> Indexing with any class name (dot or bracket syntax) returns its scoped name.
function M.sheet(css_path)
  return setmetatable({ __css_path = css_path }, sheet_metatable)
end

return M
