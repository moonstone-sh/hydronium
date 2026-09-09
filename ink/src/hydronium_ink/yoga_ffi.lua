--[[
  hydronium_ink.yoga_ffi -- LuaJIT FFI binding to the real, upstream
  facebook/yoga C API (vendored at native/vendor/yoga, see VENDORED.md for
  the pinned tag/commit; native/build.zig cross-compiles it into
  `libyogacore` for five target triples with zero CMake).

  This file is deliberately the ONLY place in this package that touches
  `ffi.cdef`/raw cdata: everything else (host/terminal.lua) goes through
  the idiomatic `YogaNode` wrapper below, never the raw C function table.

  Why hand-write this instead of using an existing "Lua Yoga binding": none
  exists that is simultaneously maintained, LuaCATS-typed, and portable --
  see docs/HYDRONIUM_INK_PACKAGING_DECISION.md-adjacent research (lyoga:
  dead since 2019; Flow: Luau, not Lua 5.1-5.4/LuaJIT, ~3yr stale). The
  flexbox algorithm itself is entirely upstream Yoga's, untouched -- this
  file only exposes its already-stable C API (`Yoga.h`, specifically
  YGNode.h/YGNodeStyle.h/YGNodeLayout.h) to Lua.

  Enums are passed as plain `int`, not declared as C `enum` types in the
  cdef below -- standard LuaJIT FFI practice, since it avoids depending on
  the compiler's enum layout choice. The numeric values in the constant
  tables near the bottom of this file are copied directly from
  native/vendor/yoga/YGEnums.h's declaration order (plain sequential
  0-based C enums, no explicit values for any member used here).

  LOADING: `ffi.load("yogacore")` first, using Moonstone's native library
  projection. A packaged dependency also gets a stable
  `MOONSTONE_PACKAGE_ROOT_HYDRONIUM_INK` path; loading the collected library
  from that root is the deterministic fallback when macOS strips or ignores a
  DYLD_* search variable across a protected process boundary. For local path
  development, this file finally falls back to the specific
  `native/dist/<triple>/libyogacore.<ext>` this repo's own build.zig
  produces, located relative to THIS FILE's own path via `debug.getinfo`
  (zero absolute/hardcoded paths, the same technique this repo's Neovim
  plugin already uses -- see CLAUDE.md). This fallback is explicitly a
  local-dev convenience, not how a real consumer of a published
  `hydronium-ink` would ever need to load this.
--]]

local ffi = require("ffi")

ffi.cdef([[
typedef struct YGNode* YGNodeRef;
typedef const struct YGNode* YGNodeConstRef;

YGNodeRef YGNodeNew(void);
void YGNodeFree(YGNodeRef node);
void YGNodeFreeRecursive(YGNodeRef node);

void YGNodeInsertChild(YGNodeRef node, YGNodeRef child, size_t index);
void YGNodeRemoveChild(YGNodeRef node, YGNodeRef child);
void YGNodeRemoveAllChildren(YGNodeRef node);
size_t YGNodeGetChildCount(YGNodeConstRef node);

void YGNodeCalculateLayout(
    YGNodeRef node,
    float availableWidth,
    float availableHeight,
    int ownerDirection);

float YGNodeLayoutGetLeft(YGNodeConstRef node);
float YGNodeLayoutGetTop(YGNodeConstRef node);
float YGNodeLayoutGetWidth(YGNodeConstRef node);
float YGNodeLayoutGetHeight(YGNodeConstRef node);
float YGNodeLayoutGetBorder(YGNodeConstRef node, int edge);
float YGNodeLayoutGetPadding(YGNodeConstRef node, int edge);

void YGNodeStyleSetDirection(YGNodeRef node, int direction);
void YGNodeStyleSetFlexDirection(YGNodeRef node, int flexDirection);
void YGNodeStyleSetJustifyContent(YGNodeRef node, int justifyContent);
void YGNodeStyleSetAlignItems(YGNodeRef node, int alignItems);
void YGNodeStyleSetAlignContent(YGNodeRef node, int alignContent);
void YGNodeStyleSetFlexWrap(YGNodeRef node, int flexWrap);

void YGNodeStyleSetFlexGrow(YGNodeRef node, float flexGrow);
void YGNodeStyleSetFlexShrink(YGNodeRef node, float flexShrink);
void YGNodeStyleSetFlexBasis(YGNodeRef node, float flexBasis);
void YGNodeStyleSetFlexBasisAuto(YGNodeRef node);

void YGNodeStyleSetWidth(YGNodeRef node, float width);
void YGNodeStyleSetWidthAuto(YGNodeRef node);
void YGNodeStyleSetHeight(YGNodeRef node, float height);
void YGNodeStyleSetHeightAuto(YGNodeRef node);

void YGNodeStyleSetPadding(YGNodeRef node, int edge, float padding);
void YGNodeStyleSetBorder(YGNodeRef node, int edge, float border);
void YGNodeStyleSetMargin(YGNodeRef node, int edge, float margin);
void YGNodeStyleSetGap(YGNodeRef node, int gutter, float gapLength);

void YGNodeStyleSetPositionType(YGNodeRef node, int positionType);
void YGNodeStyleSetPosition(YGNodeRef node, int edge, float position);
void YGNodeStyleSetDisplay(YGNodeRef node, int display);
void YGNodeStyleSetOverflow(YGNodeRef node, int overflow);
]])

-- POSIX `realpath(3)`, used only to resolve the symlink case below --
-- deliberately not `ffi.load`'d from a specific library: on POSIX this
-- symbol is already present in the process's own symbol table (libc is
-- always linked), so `ffi.C` resolves it directly with no extra loader
-- work. Not declared/used on Windows (see this_file_dir()'s pcall around
-- every call site) -- Windows has no `realpath`, and the moon-sync
-- symlink case this exists for is POSIX-specific (`moon sync` on Windows
-- materializes `path:` dependencies differently).
if ffi.os ~= "Windows" then
  -- Passed a pre-allocated `resolved_path` buffer (never NULL), so on
  -- success this returns that same pointer, not a malloc'd one -- nothing
  -- here to free.
  ffi.cdef([[
char *realpath(const char *path, char *resolved_path);
]])
end

--- Resolves this file's own directory, dependency-free (no `debug.getinfo`
--- caller assumptions beyond level 1 -- this IS the currently-running
--- chunk). Mirrors the technique `config/nvim/lua/plugins/luax.lua`'s
--- `hydronium.nvim` spec already uses to avoid hardcoded absolute paths.
---
--- Resolves through symlinks via `realpath(3)` where available: `moon
--- sync` materializes a `path:` dependency's modules as symlinks INTO the
--- real source tree (verified directly: `.moonstone/env/share/lua/5.1/
--- hydronium_ink/yoga_ffi.lua -> .../ink/src/hydronium_ink/yoga_ffi.lua`
--- in a real scratch consumer project) -- `debug.getinfo`'s `source`
--- field is the symlink path LUA_PATH actually opened, not its target, so
--- computing a `native/dist/...` sibling path relative to it without
--- resolving the symlink first lands inside the CONSUMER's own
--- `.moonstone/env/` tree instead of this package's real `native/`
--- directory. Falls back to the unresolved path if `realpath` fails or
--- isn't declared (Windows, or the path already isn't a symlink) --
--- correct in the common case (this file loaded directly from its real
--- location, e.g. via this repo's own `tests/runner.lua`) and a safe
--- no-op otherwise (load_yogacore's caller already handles this
--- function's result not existing, by trying and failing to load it).
--- @return string
local function this_file_dir()
  local info = debug.getinfo(1, "S")
  local src = (info and info.source and info.source:gsub("^@", "")) or ""

  if ffi.os ~= "Windows" then
    local buf = ffi.new("char[?]", 4096)
    local resolved = ffi.C.realpath(src, buf)
    if resolved ~= nil then
      src = ffi.string(resolved)
    end
  end

  return src:match("^(.*)[/\\][^/\\]+$") or "."
end

--- @return string triple, string filename
local function local_dev_target()
  local os_name = ffi.os -- "OSX" | "Linux" | "Windows" | ...
  local arch = ffi.arch -- "arm64" | "x64" | "x86" | ...
  if os_name == "OSX" then
    return (arch == "arm64" and "aarch64-macos" or "x86_64-macos"), "libyogacore.dylib"
  elseif os_name == "Linux" then
    return (arch == "arm64" and "aarch64-linux-gnu" or "x86_64-linux-gnu"), "libyogacore.so"
  elseif os_name == "Windows" then
    return "x86_64-windows-gnu", "yogacore.dll"
  end
  error("hydronium_ink.yoga_ffi: no local-dev prebuilt target for ffi.os=" .. tostring(os_name))
end

--- @return ffi.namespace* yogacore
local function load_yogacore()
  local ok, lib = pcall(ffi.load, "yogacore")
  if ok then return lib end

  local triple, filename = local_dev_target()
  local package_root = os.getenv("MOONSTONE_PACKAGE_ROOT_HYDRONIUM_INK")
  local packaged_error
  if package_root and package_root ~= "" then
    local packaged = package_root .. "/" .. filename
    local package_ok, package_lib = pcall(ffi.load, packaged)
    if package_ok then return package_lib end
    packaged_error = " or the packaged library at " .. packaged .. " (" .. tostring(package_lib) .. ")"
  end

  -- this file lives at <pkg>/src/hydronium_ink/yoga_ffi.lua; native/ is two
  -- levels up from hydronium_ink/ (out of src/, into <pkg>/native/).
  local candidate = this_file_dir() .. "/../../native/dist/" .. triple .. "/" .. filename
  local dev_ok, dev_lib = pcall(ffi.load, candidate)
  if dev_ok then return dev_lib end

  error(
    "hydronium_ink.yoga_ffi: could not load libyogacore via the OS loader search"
      .. " (" .. tostring(lib) .. ")"
      .. (packaged_error or "")
      .. " or the local-dev fallback at "
      .. candidate .. " (" .. tostring(dev_lib) .. ")."
      .. " Run `zig build` in ink/native/ to produce the local-dev artifact.",
    0
  )
end

local C = load_yogacore()

--- Enum values copied from native/vendor/yoga/YGEnums.h's declaration
--- order (sequential 0-based C enums). Passed to the FFI layer as plain
--- `int`, never as a cdef'd C `enum` type -- see this file's own doc
--- comment for why.
local Enum = {
  Direction = { Inherit = 0, LTR = 1, RTL = 2 },
  FlexDirection = { Column = 0, ColumnReverse = 1, Row = 2, RowReverse = 3 },
  Justify = {
    FlexStart = 0,
    Center = 1,
    FlexEnd = 2,
    SpaceBetween = 3,
    SpaceAround = 4,
    SpaceEvenly = 5,
  },
  Align = {
    Auto = 0,
    FlexStart = 1,
    Center = 2,
    FlexEnd = 3,
    Stretch = 4,
    Baseline = 5,
    SpaceBetween = 6,
    SpaceAround = 7,
    SpaceEvenly = 8,
  },
  Wrap = { NoWrap = 0, Wrap = 1, WrapReverse = 2 },
  Edge = {
    Left = 0,
    Top = 1,
    Right = 2,
    Bottom = 3,
    Start = 4,
    End = 5,
    Horizontal = 6,
    Vertical = 7,
    All = 8,
  },
  Gutter = { Column = 0, Row = 1, All = 2 },
  PositionType = { Static = 0, Relative = 1, Absolute = 2 },
  Display = { Flex = 0, None = 1, Contents = 2 },
  Overflow = { Visible = 0, Hidden = 1, Scroll = 2 },
}

---@class hydronium_ink.YogaNode
---@field package ptr ffi.cdata* A `YGNodeRef` (opaque `struct YGNode*`).
local YogaNode = {}
YogaNode.__index = YogaNode

---Allocates a new Yoga node (`YGNodeNew`).
---@return hydronium_ink.YogaNode
function YogaNode.new()
  return setmetatable({ ptr = C.YGNodeNew() }, YogaNode)
end

---Frees this node, disconnecting it from its owner and children
---(`YGNodeFree` -- safe to call on a node with attached children; it does
---not free them, matching this module's one-Yoga-node-per-host-node
---lifecycle where each host node is freed individually as it is removed).
function YogaNode:free()
  C.YGNodeFree(self.ptr)
end

---Inserts `child` at `index` (0-based, matching Yoga's own C API).
---@param child hydronium_ink.YogaNode
---@param index integer 0-based
function YogaNode:insertChild(child, index)
  C.YGNodeInsertChild(self.ptr, child.ptr, index)
end

---@param child hydronium_ink.YogaNode
function YogaNode:removeChild(child)
  C.YGNodeRemoveChild(self.ptr, child.ptr)
end

function YogaNode:removeAllChildren()
  C.YGNodeRemoveAllChildren(self.ptr)
end

---@return integer
function YogaNode:childCount()
  return tonumber(C.YGNodeGetChildCount(self.ptr))
end

---Runs Yoga's real flexbox algorithm over the tree rooted at this node.
---@param availableWidth number
---@param availableHeight number
function YogaNode:calculateLayout(availableWidth, availableHeight)
  C.YGNodeCalculateLayout(self.ptr, availableWidth, availableHeight, Enum.Direction.LTR)
end

---@class hydronium_ink.ComputedLayout
---@field left number
---@field top number
---@field width number
---@field height number
---@field clientWidth number Content-box width: `width` minus left+right border and padding.
---@field clientHeight number Content-box height: `height` minus top+bottom border and padding.

---Reads back the layout `calculateLayout` produced for this node. Must
---be called before this node is freed -- `clientWidth`/`clientHeight`
---specifically exist to let callers (host/terminal.lua's
---resolvePositions) capture the content-box size into `node._layout`
---while the real Yoga node is still alive, for `measureElement()` to
---read back later, long after this node itself has been freed (see
---buildYogaTree's own doc comment on the per-paint alloc/free lifecycle).
---@return hydronium_ink.ComputedLayout
function YogaNode:getComputedLayout()
  local border = C.YGNodeLayoutGetBorder(self.ptr, Enum.Edge.Left) + C.YGNodeLayoutGetBorder(self.ptr, Enum.Edge.Right)
  local vBorder = C.YGNodeLayoutGetBorder(self.ptr, Enum.Edge.Top) + C.YGNodeLayoutGetBorder(self.ptr, Enum.Edge.Bottom)
  local padding = C.YGNodeLayoutGetPadding(self.ptr, Enum.Edge.Left) + C.YGNodeLayoutGetPadding(self.ptr, Enum.Edge.Right)
  local vPadding = C.YGNodeLayoutGetPadding(self.ptr, Enum.Edge.Top) + C.YGNodeLayoutGetPadding(self.ptr, Enum.Edge.Bottom)
  local width = C.YGNodeLayoutGetWidth(self.ptr)
  local height = C.YGNodeLayoutGetHeight(self.ptr)
  return {
    left = C.YGNodeLayoutGetLeft(self.ptr),
    top = C.YGNodeLayoutGetTop(self.ptr),
    width = width,
    height = height,
    clientWidth = width - border - padding,
    clientHeight = height - vBorder - vPadding,
  }
end

---@class hydronium_ink.YogaStyle
---@field flexDirection? "column"|"column-reverse"|"row"|"row-reverse"
---@field justifyContent? "flex-start"|"center"|"flex-end"|"space-between"|"space-around"|"space-evenly"
---@field alignItems? "auto"|"flex-start"|"center"|"flex-end"|"stretch"|"baseline"|"space-between"|"space-around"|"space-evenly"
---@field flexWrap? "nowrap"|"wrap"|"wrap-reverse"
---@field flexGrow? number
---@field flexShrink? number
---@field flexBasis? number|"auto"
---@field width? number|"auto"
---@field height? number|"auto"
---@field padding? number Applied to `Edge.All`.
---@field paddingX? number Applied to `Edge.Horizontal`, overrides `padding` on that axis.
---@field paddingY? number Applied to `Edge.Vertical`, overrides `padding` on that axis.
---@field border? number Applied to `Edge.All`.
---@field gap? number Applied to `Gutter.All`.
---@field margin? number Applied to `Edge.All`.
---@field marginX? number Applied to `Edge.Horizontal`, overrides `margin` on that axis.
---@field marginY? number Applied to `Edge.Vertical`, overrides `margin` on that axis.
---@field position? "relative"|"absolute"
---@field top? number
---@field right? number
---@field bottom? number
---@field left? number
---@field display? "flex"|"none"
---@field overflow? "visible"|"hidden"|"scroll"

local FLEX_DIRECTION = {
  column = Enum.FlexDirection.Column,
  ["column-reverse"] = Enum.FlexDirection.ColumnReverse,
  row = Enum.FlexDirection.Row,
  ["row-reverse"] = Enum.FlexDirection.RowReverse,
}

local JUSTIFY_CONTENT = {
  ["flex-start"] = Enum.Justify.FlexStart,
  center = Enum.Justify.Center,
  ["flex-end"] = Enum.Justify.FlexEnd,
  ["space-between"] = Enum.Justify.SpaceBetween,
  ["space-around"] = Enum.Justify.SpaceAround,
  ["space-evenly"] = Enum.Justify.SpaceEvenly,
}

local ALIGN = {
  auto = Enum.Align.Auto,
  ["flex-start"] = Enum.Align.FlexStart,
  center = Enum.Align.Center,
  ["flex-end"] = Enum.Align.FlexEnd,
  stretch = Enum.Align.Stretch,
  baseline = Enum.Align.Baseline,
  ["space-between"] = Enum.Align.SpaceBetween,
  ["space-around"] = Enum.Align.SpaceAround,
  ["space-evenly"] = Enum.Align.SpaceEvenly,
}

-- "nowrap" (no hyphen) matches real Ink's own Box `flexWrap` prop spelling,
-- not Yoga's internal `YGWrapNoWrap` naming.
local FLEX_WRAP = {
  nowrap = Enum.Wrap.NoWrap,
  wrap = Enum.Wrap.Wrap,
  ["wrap-reverse"] = Enum.Wrap.WrapReverse,
}

local POSITION_TYPE = {
  relative = Enum.PositionType.Relative,
  absolute = Enum.PositionType.Absolute,
}

local DISPLAY = {
  flex = Enum.Display.Flex,
  none = Enum.Display.None,
}

local OVERFLOW = {
  visible = Enum.Overflow.Visible,
  hidden = Enum.Overflow.Hidden,
  scroll = Enum.Overflow.Scroll,
}

---Applies a table of style properties to this node. Unset fields are left
---at Yoga's own defaults (this is called once per node per paint in
---host/terminal.lua, on a freshly-created-or-reused node, not incrementally
---diffed -- matching that module's existing "recompute from props every
---paint" approach for the block-stack layout this replaces).
---@param style hydronium_ink.YogaStyle
function YogaNode:setStyle(style)
  if style.flexDirection then
    C.YGNodeStyleSetFlexDirection(self.ptr, FLEX_DIRECTION[style.flexDirection])
  end
  if style.justifyContent then
    C.YGNodeStyleSetJustifyContent(self.ptr, JUSTIFY_CONTENT[style.justifyContent])
  end
  if style.alignItems then
    C.YGNodeStyleSetAlignItems(self.ptr, ALIGN[style.alignItems])
  end
  if style.flexWrap then
    C.YGNodeStyleSetFlexWrap(self.ptr, FLEX_WRAP[style.flexWrap])
  end
  if style.flexGrow then
    C.YGNodeStyleSetFlexGrow(self.ptr, style.flexGrow)
  end
  if style.flexShrink then
    C.YGNodeStyleSetFlexShrink(self.ptr, style.flexShrink)
  end
  if style.flexBasis then
    if style.flexBasis == "auto" then
      C.YGNodeStyleSetFlexBasisAuto(self.ptr)
    else
      C.YGNodeStyleSetFlexBasis(self.ptr, style.flexBasis)
    end
  end
  if style.width then
    if style.width == "auto" then
      C.YGNodeStyleSetWidthAuto(self.ptr)
    else
      C.YGNodeStyleSetWidth(self.ptr, style.width)
    end
  end
  if style.height then
    if style.height == "auto" then
      C.YGNodeStyleSetHeightAuto(self.ptr)
    else
      C.YGNodeStyleSetHeight(self.ptr, style.height)
    end
  end
  if style.padding then
    C.YGNodeStyleSetPadding(self.ptr, Enum.Edge.All, style.padding)
  end
  if style.paddingX then
    C.YGNodeStyleSetPadding(self.ptr, Enum.Edge.Horizontal, style.paddingX)
  end
  if style.paddingY then
    C.YGNodeStyleSetPadding(self.ptr, Enum.Edge.Vertical, style.paddingY)
  end
  if style.border then
    C.YGNodeStyleSetBorder(self.ptr, Enum.Edge.All, style.border)
  end
  if style.gap then
    C.YGNodeStyleSetGap(self.ptr, Enum.Gutter.All, style.gap)
  end
  if style.margin then
    C.YGNodeStyleSetMargin(self.ptr, Enum.Edge.All, style.margin)
  end
  if style.marginX then
    C.YGNodeStyleSetMargin(self.ptr, Enum.Edge.Horizontal, style.marginX)
  end
  if style.marginY then
    C.YGNodeStyleSetMargin(self.ptr, Enum.Edge.Vertical, style.marginY)
  end
  if style.position then
    C.YGNodeStyleSetPositionType(self.ptr, POSITION_TYPE[style.position])
  end
  if style.top then
    C.YGNodeStyleSetPosition(self.ptr, Enum.Edge.Top, style.top)
  end
  if style.right then
    C.YGNodeStyleSetPosition(self.ptr, Enum.Edge.Right, style.right)
  end
  if style.bottom then
    C.YGNodeStyleSetPosition(self.ptr, Enum.Edge.Bottom, style.bottom)
  end
  if style.left then
    C.YGNodeStyleSetPosition(self.ptr, Enum.Edge.Left, style.left)
  end
  if style.display then
    C.YGNodeStyleSetDisplay(self.ptr, DISPLAY[style.display])
  end
  if style.overflow then
    C.YGNodeStyleSetOverflow(self.ptr, OVERFLOW[style.overflow])
  end
end

return {
  newNode = YogaNode.new,
  Enum = Enum,
}
