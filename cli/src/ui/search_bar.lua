--[[
  hydronium_cli.ui.search_bar -- renders the filter field as chips.

  A recognised `field:value` draws as a two-tone chip: the field on a vibrant
  background in white, the value on a muted background beside it. An
  unrecognised field draws in the same shape but in a warning colour, so a
  typo LOOKS wrong while you type instead of silently filtering everything
  away.

  THE TOKEN UNDER THE CARET IS NOT CHIPPED. It renders as raw text with the
  caret in it. A chip has no sensible place to put a caret, and "the thing I
  am editing looks like text, the things I finished look like chips" is the
  behaviour every real tag input has. Move the caret away and the token snaps
  into a chip.

  WRAPPING is handled by flex, not by this module. Each chip is a Box, and a
  Box is a flex item; Yoga never splits a flex item, so a chip either fits on
  the current row or moves to the next one whole. That is why the container
  below sets `flexWrap = "wrap"` and nothing here measures text: atomic
  wrapping falls out of the layout engine rather than being re-implemented.

  COLOR PROFILE: the chip design above is the TRUECOLOR design. It does not
  survive unmodified into lower-color terminals -- see `derive_chip_colors`'s
  own doc comment for ansi256, and `STRUCTURAL_STYLE`'s for ansi16/none. This
  module reads `hooks.useColorProfile()` (reactively, in `M.create`'s render
  closure) and threads the result through `M.render`/`M.build_colors` as a
  plain `profile` argument, rather than reaching for the hook from `M.render`
  itself -- `M.render` is also called directly by stories and specs with no
  mounted component/hook context at all, so it takes `opts.profile`
  explicitly instead (defaulting to "truecolor", matching a session with no
  profile override).
--]]

local hydronium = require("hydronium")
local ink = require("hydronium_ink")
local hooks = require("hydronium_ink.hooks")
local ink_color = require("hydronium_ink.color")
local oklab = require("hydronium_oklab_utils")
local query = require("query")
local search_field = require("ui.search_field")

local M = {}

--- The bar's focus id. A stable constant rather than a generated one so the
--- `/` binding elsewhere can focus it by name without having to be handed a
--- reference through props.
M.FOCUS_ID = "hydronium-cli.filter"

--[[
  CHIP COLOR DERIVATION -- this is the reference example (linked from
  hydronium/oklab-utils' own REGISTRY_README.md) of how a Hydronium app
  should use that package's generic contrast math, rather than terminal
  palette names.

  The chips used to be `backgroundColor = "blue"`/`"yellow"`/`"cyan"`/etc:
  the 8/16-colour palette hydronium_ink.color speaks (see that file's own
  top comment). Those names render however the user's OWN terminal theme
  remaps that slot -- there is no way to reason about contrast against a
  color this program never actually knows the value of, and a theme that
  makes "yellow" pale and "white" cream-colored is exactly what made these
  chips hard to read in the first place.

  The fix is absolute OKLCH colors, run through three fully generic
  oklab-utils calls with no chip-specific knowledge inside oklab-utils
  itself:
    1. `ensure_contrast(chip_bg, terminal_bg, BG_SEPARATION_LC)` -- nudge
       the chip's own background just far enough from the REAL detected
       terminal background (hydronium_ink.terminal_background, OSC 11) that
       it doesn't disappear into it. Skipped gracefully when detection
       fails (`terminal_bg == nil`): the role's plain default is used as-is.
    2. `readable_on(chip_bg)` -- pick a starting near-black/near-white text
       color for that background.
    3. `ensure_contrast(text, chip_bg, TEXT_LC)` -- push that text color
       until it actually clears APCA's floor for small/bold text.
  Every hue below was chosen only to preserve this bar's previous color
  IDENTITY (blue field / yellow warning / cyan selection / white value) --
  that choice is this program's own, not oklab-utils' concern.
--]]

local CHIP_ROLES = {
  field         = { hue = 254, l = 0.55, c = 0.150 }, -- was "blue"
  unknown_field = { hue = 95,  l = 0.80, c = 0.170 }, -- was "yellow"
  value         = { hue = 90,  l = 0.93, c = 0.015 }, -- was "white"/"black"
  selection     = { hue = 221, l = 0.75, c = 0.100 }, -- was "cyan"
  caret         = { hue = 90,  l = 0.95, c = 0.010 }, -- was "white"/"black" (inverted cell)
}

-- Modest: this is chip-background-vs-terminal-background separation, not
-- text legibility. TEXT_LC 60 is APCA's own commonly-cited floor for
-- small/bold text (see hydronium_oklab_utils.lc's own doc comment).
local BG_SEPARATION_LC = 20
local TEXT_LC = 60

-- ansi256's 256-slot nearest-color quantization can undershoot a target
-- that was only ever verified in continuous truecolor space (see
-- `derive_chip_colors`'s own doc comment below) -- this many extra
-- ensure_contrast passes, each asking for a HIGHER truecolor target than
-- the last, are tried before giving up and shipping the best truecolor
-- result found. 8 passes at +6 each covers the entire achievable APCA
-- range (roughly 0..108) from any TEXT_LC-reaching starting point.
local ANSI256_VERIFY_PASSES = 8
local ANSI256_VERIFY_STEP_LC = 6

--- ansi16/"none" REPLACE the color pipeline entirely rather than degrade it:
--- ansi16's own 16 RGB values are THEME-DEFINED (a real terminal theme picks
--- them, hydronium_ink.color.ansi16_rgb's own table is only an ASSUMED
--- value used for quantization/preview, never a promise about what a real
--- user's terminal actually shows) -- so computing APCA contrast against an
--- assumed RGB for an ansi16 slot is false precision, not a real
--- guarantee. The legible move for both ansi16 and "none" (NO_COLOR) is the
--- same one real terminal UIs already lean on: inverse video and bold
--- against the terminal's OWN default fg/bg, never a chosen hue -- exactly
--- the two flags every terminal, of any age or theme, renders reliably.
---
--- Every role gets a NON-EMPTY combination of {inverse, bold} (never a bare
--- `{}`, which would be visually identical to plain, undecorated text) so
--- each one is at least legible as "something," but with only 2 flags and 5
--- roles (field/unknown_field/value/selection/caret) two pairs necessarily
--- repeat a combination -- chosen deliberately on pairs that never actually
--- render in the same place at once, so the collision is never visible in
--- practice:
---   * `field`/`caret` share {inverse, bold}: a completed OTHER token's chip
---     label vs. the single-cell caret marker inside the token CURRENTLY
---     being edited (which is never itself chipped -- see this file's own
---     top doc comment) -- different shapes (padded multi-cell label vs. one
---     cell) even where the SGR is identical.
---   * `unknown_field`/`selection` share {bold} alone: an unknown-field
---     chip's label vs. a selection highlight, which only ever paints over
---     the SAME not-yet-chipped raw text a caret would otherwise occupy --
---     never over a completed chip.
--- `value` gets {inverse} alone, distinguishing it from both its own
--- `field`/`unknown_field` label (which adds bold) and from `selection`
--- (which has no inverse) -- the one combination not reused anywhere.
local STRUCTURAL_STYLE = {
  field         = { inverse = true, bold = true },
  unknown_field = { bold = true },
  value         = { inverse = true },
  selection     = { bold = true },
  caret         = { inverse = true, bold = true },
}

--- One chip role's {bg, fg} for `capability` ("truecolor" or "ansi256" --
--- ansi16/"none" use `STRUCTURAL_STYLE` above instead, never this).
---
--- truecolor: exactly the three-step pipeline described in this file's own
--- top comment, unchanged.
---
--- ansi256: the SAME design (same hue/lightness/chroma target, same
--- ensure_contrast(TEXT_LC) pass in continuous OKLCH space) -- ansi256's 256
--- RGB slots (16-255) are FIXED, standard, and known ahead of time (unlike
--- ansi16's theme-guessed ones), so contrast math against them is real, not
--- false precision -- but a target only verified in continuous space is not
--- verified against what will actually PAINT once `hydronium_ink.color`
--- snaps it to its nearest of only 256 slots, which can undershoot. This
--- re-checks the REAL post-quantization Lc (`ink_color.effective_srgb` +
--- `oklab.lc`, the same pair `cli/tests/search_bar_spec.lua` asserts with)
--- and, only if it still falls short, asks `ensure_contrast` for a
--- progressively higher truecolor TEXT target and re-quantizes.
---
--- That alone is not always enough: the text color can CAP OUT (pure black
--- or white -- `ensure_contrast` has nowhere further to push it) while
--- still short once quantized, e.g. a light, low-chroma background whose
--- own nearest-256 slot lands lighter than the continuous value it was
--- computed against. When that happens, this nudges the BACKGROUND instead
--- (`ensure_contrast` is symmetric in which color it moves -- pushing `bg`
--- away from the now-fixed `fg` is the exact same machinery, just applied
--- to the other side of the pair), again re-verifying against the real
--- quantized result each step. Between the two passes this clears
--- `TEXT_LC` for every role this file ships (see
--- `cli/tests/search_bar_spec.lua`'s own assertions); on a role neither
--- pass can rescue, whatever was last computed ships anyway --
--- `ensure_contrast` always returns its best achievable score when a
--- target is out of reach, so this never regresses below a single
--- untargeted pass.
--- @param role { hue: number, l: number, c: number }
--- @param terminal_bg hydronium_oklab_utils.Color|nil
--- @param capability "truecolor"|"ansi256"
--- @return hydronium_oklab_utils.Color bg, hydronium_oklab_utils.Color fg
local function derive_chip_colors(role, terminal_bg, capability)
  local bg = oklab.oklch(role.l, role.c, role.hue)
  if terminal_bg then
    bg = oklab.ensure_contrast(bg, terminal_bg, BG_SEPARATION_LC)
  end
  local fg = oklab.ensure_contrast(oklab.readable_on(bg), bg, TEXT_LC)

  if capability == "ansi256" then
    local function quantized_lc()
      local eff_bg = ink_color.effective_srgb(ink_color.resolve(bg), capability)
      local eff_fg = ink_color.effective_srgb(ink_color.resolve(fg), capability)
      return oklab.lc(
        oklab.srgb(eff_fg.r, eff_fg.g, eff_fg.b),
        oklab.srgb(eff_bg.r, eff_bg.g, eff_bg.b))
    end

    local target = TEXT_LC
    for _ = 1, ANSI256_VERIFY_PASSES do
      if math.abs(quantized_lc()) >= TEXT_LC then break end
      target = target + ANSI256_VERIFY_STEP_LC
      fg = oklab.ensure_contrast(fg, bg, target)
    end

    if math.abs(quantized_lc()) < TEXT_LC then
      local bgTarget = TEXT_LC
      for _ = 1, ANSI256_VERIFY_PASSES do
        if math.abs(quantized_lc()) >= TEXT_LC then break end
        bgTarget = bgTarget + ANSI256_VERIFY_STEP_LC
        bg = oklab.ensure_contrast(bg, fg, bgTarget)
      end
    end
  end

  return bg, fg
end

--- Builds every chip role's style against one (possibly nil, meaning
--- "unknown") terminal background, for `capability`. Not local/private:
--- stories and specs call this directly to get a deterministic palette
--- without depending on real OSC 11 detection (which needs a real TTY --
--- see hydronium_ink.terminal_background) or a real color-profile
--- environment.
---
--- SHAPE DEPENDS ON `capability`: "truecolor"/"ansi256" (the default)
--- return `{ bg: Color, fg: Color }` per role, meant for
--- `backgroundColor`/`color` props (see `style_text_props` below);
--- "ansi16"/"none" return `STRUCTURAL_STYLE`'s `{ inverse?, bold? }` per
--- role instead, meant for those SAME-NAMED Text props directly. A caller
--- that only ever reads through `style_text_props` doesn't need to care
--- which shape it got.
--- @param terminal_bg hydronium_oklab_utils.Color|nil
--- @param capability? "truecolor"|"ansi256"|"ansi16"|"none"
--- @return table<string, { bg: hydronium_oklab_utils.Color, fg: hydronium_oklab_utils.Color }|{ inverse: boolean|nil, bold: boolean|nil }>
function M.build_colors(terminal_bg, capability)
  capability = capability or "truecolor"
  if capability == "ansi16" or capability == "none" then
    return STRUCTURAL_STYLE
  end
  local built = {}
  for name, role in pairs(CHIP_ROLES) do
    local bg, fg = derive_chip_colors(role, terminal_bg, capability)
    built[name] = { bg = bg, fg = fg }
  end
  return built
end

--- Turns one `M.build_colors(...)` role entry into Text props: `{bg, fg}`
--- becomes `backgroundColor`/`color` (truecolor/ansi256); a structural
--- `{inverse?, bold?}` entry (ansi16/none) passes those flags straight
--- through, since it already names real Text props. Always returns a FRESH
--- table -- callers (`chip`/`rawText` below) safely add more props (`bold`
--- on top of a color pair, `key`) onto the result without risking a mutate
--- of `STRUCTURAL_STYLE`'s own shared, reused-every-render tables.
--- @param style { bg: hydronium_oklab_utils.Color, fg: hydronium_oklab_utils.Color }|{ inverse: boolean|nil, bold: boolean|nil }
--- @return table props
local function style_text_props(style)
  if style.bg ~= nil or style.fg ~= nil then
    return { backgroundColor = style.bg, color = style.fg }
  end
  return { inverse = style.inverse, bold = style.bold }
end

-- Detected and derived at most once per process PER color profile (an OSC
-- 11 round trip has a real, if small, timeout cost, and the real terminal
-- background does not change mid-session -- but the color PROFILE can, via
-- Ink Lab's live profile control or a session's `setColorProfile`, so the
-- built-colors cache is keyed by it rather than computed once and reused
-- regardless). `false` (as opposed to the initial `nil`) marks "we already
-- tried detection" so a failed/unavailable detection -- e.g. this process
-- is not attached to a real TTY at all, the ordinary case under the test
-- runner -- is not retried on every render.
local detected_bg, built_colors_by_profile = nil, {}
--- Memoized style table per chip role for `profile`, detecting the real
--- terminal background (falling back to each role's plain default -- see
--- `derive_chip_colors` -- when detection is unavailable, and unused
--- entirely for ansi16/none -- see `M.build_colors`) on first use per
--- profile.
--- @param profile? "truecolor"|"ansi256"|"ansi16"|"none"
--- @return table<string, table>
local function colors(profile)
  profile = profile or "truecolor"
  if not built_colors_by_profile[profile] then
    if detected_bg == nil then
      local ok, bg = pcall(ink.terminal_background)
      detected_bg = (ok and bg) or false
    end
    built_colors_by_profile[profile] = M.build_colors(detected_bg or nil, profile)
  end
  return built_colors_by_profile[profile]
end

--- @param token table A hydronium_cli.QueryToken
--- @param key integer
--- @param profile "truecolor"|"ansi256"|"ansi16"|"none"
--- @return table element
local function chip(token, key, profile)
  local known = token.type == "tag"
  local label = (token.negated and "-" or "") .. token.field .. ":"
  local role_colors = colors(profile)
  local field_props = style_text_props(role_colors[known and "field" or "unknown_field"])
  local value_props = style_text_props(role_colors.value)
  -- The field label is always bold, independent of profile/color -- for
  -- truecolor/ansi256 this is on top of the derived {bg, fg} pair
  -- (style_text_props doesn't set it, since that pair carries no bold of
  -- its own); for ansi16/none, STRUCTURAL_STYLE's own `field`/
  -- `unknown_field` entries already set it, so this is a harmless re-set.
  field_props.bold = true
  return hydronium.h(ink.Box, { key = key, flexDirection = "row" },
    hydronium.h(ink.Text, field_props, " " .. label .. " "),
    hydronium.h(ink.Text, value_props,
      " " .. (token.value ~= "" and token.value or "\226\128\166") .. " ")
  )
end

--- Raw text with a caret rendered as an inverted cell.
---
--- The caret is drawn rather than placed with a real terminal cursor because
--- the host parks the hardware cursor below the frame after every changed
--- paint (see useCursor's own doc comment) -- a cursor positioned into the
--- field would be moved away again on the very next repaint.
--- @param text string
--- @param caret integer|nil 0-based offset within `text`, or nil
--- @param key integer
--- @param selFrom integer|nil
--- @param selTo integer|nil
--- @param profile "truecolor"|"ansi256"|"ansi16"|"none"
--- @return table element
local function rawText(text, caret, key, selFrom, selTo, profile)
  local parts = {}
  local function push(str, props)
    if str ~= "" then
      parts[#parts + 1] = hydronium.h(ink.Text, props or {}, str)
    end
  end

  if selFrom and selTo and selTo > selFrom then
    local selection_props = style_text_props(colors(profile).selection)
    push(text:sub(1, selFrom))
    push(text:sub(selFrom + 1, selTo), selection_props)
    push(text:sub(selTo + 1))
  elseif caret then
    push(text:sub(1, caret))
    -- The caret sits ON the next character, or on a trailing space when it is
    -- at the very end -- otherwise an end-of-input caret would be invisible.
    local under = text:sub(caret + 1, caret + 1)
    local caret_props = style_text_props(colors(profile).caret)
    push(under ~= "" and under or " ", caret_props)
    push(text:sub(caret + 2))
  else
    push(text)
  end

  return hydronium.h(ink.Box, { key = key, flexDirection = "row" }, parts)
end

--- Builds the filter bar.
--- @param state hydronium_cli.SearchFieldState
--- @param tokens table[] From query.tokenize(state.text)
--- @param opts table|nil `{ focused = boolean, profile? = "truecolor"|"ansi256"|"ansi16"|"none" }`
---   `profile` defaults to "truecolor" -- matching a session/story with no
---   explicit color-profile override -- since `M.render` is also called
---   directly (by `search_bar.stories.lua` and `cli/tests/search_bar_spec.lua`)
---   with no mounted component/hook context to read a live one from.
--- @return table element
function M.render(state, tokens, opts)
  opts = opts or {}
  local profile = opts.profile or "truecolor"
  local caret = opts.focused and state.cursor or nil
  local selFrom, selTo = nil, nil
  if opts.focused then
    local f, t = state.anchor and math.min(state.anchor, state.cursor), state.anchor and math.max(state.anchor, state.cursor)
    if f and t and t > f then selFrom, selTo = f, t end
  end

  local children = {}
  local key = 0
  local consumed = 0

  for _, token in ipairs(tokens) do
    key = key + 1
    -- Whitespace between tokens is preserved so the rendered bar matches the
    -- text the caret arithmetic is computed against.
    if token.from > consumed + 1 then
      children[#children + 1] =
        hydronium.h(ink.Text, { key = "gap" .. key }, state.text:sub(consumed + 1, token.from - 1))
    end

    local caretInside = caret and caret >= token.from - 1 and caret <= token.to
    local selectionTouches = selFrom and selTo and not (selTo <= token.from - 1 or selFrom >= token.to)

    if token.type == "text" or caretInside or selectionTouches then
      local localCaret = caretInside and (caret - (token.from - 1)) or nil
      local lf = selectionTouches and math.max(0, selFrom - (token.from - 1)) or nil
      local lt = selectionTouches and math.min(#token.text, selTo - (token.from - 1)) or nil
      children[#children + 1] = rawText(token.text, localCaret, key, lf, lt, profile)
    else
      children[#children + 1] = chip(token, key, profile)
    end
    consumed = token.to
  end

  -- A caret sitting past the last token (typing at the end) still needs to be
  -- drawn, or the field looks unfocused exactly when it is focused.
  if caret and caret >= consumed then
    children[#children + 1] = rawText(state.text:sub(consumed + 1), caret - consumed, key + 1, nil, nil, profile)
  end

  if #children == 0 then
    children[#children + 1] = hydronium.h(ink.Text, { dimColor = true },
      "filter: method:GET  -status:2xx  duration:>100  body:\"not found\"")
  end

  return hydronium.h(ink.Box, { flexDirection = "row", flexWrap = "wrap" }, children)
end

--- The bar as a real focusable component.
---
--- Its key handling is bound to its own focus id, so it is offered input ONLY
--- while focused, and it stops propagation on everything it takes. That is
--- what keeps `q` from quitting and `f` from leaving the view while you are
--- typing a filter -- and it holds without any handler elsewhere knowing this
--- component exists, because ordering comes from the tree and the gate comes
--- from focus.
--- @param state table The CLI ui state (see ui/app.lua's new_state).
--- @return function component
function M.create(state)
  return function()
    local focus = hooks.useFocus({ id = M.FOCUS_ID })
    local manager = hooks.useFocusManager()
    local clipboard = hooks.useClipboard()

    hooks.useInput(function(input, key, evt)
      key = key or {}
      evt.stop()
      if key.escape or key["return"] then
        -- Enter commits by blurring; the filter is already live, since it
        -- reapplies on every keystroke.
        manager.blur()
        return
      end
      local next_state, intent = search_field.handle_key(state.search(), { input = input, key = key })
      state.set_search(next_state)
      state.set_search_revision(state.search_revision() + 1)
      if intent and intent.type == "copy" then
        clipboard.write(intent.text)
      end
    end, { focusId = focus.id })

    hooks.usePaste(function(text, evt)
      evt.stop()
      state.set_search(search_field.handle_key(state.search(), { type = "paste", text = text }))
      state.set_search_revision(state.search_revision() + 1)
    end, { focusId = focus.id })

    return function()
      state.search_revision()
      local field_state = state.search()
      -- Reactive getter (see hydronium_ink.hooks.useColorProfile's own doc
      -- comment) -- read here, in the per-render closure, not once at
      -- setup above, so a live profile switch (Ink Lab's control, or a real
      -- session's setColorProfile) repaints this bar in the new profile's
      -- style on the very next render.
      local profile = hooks.useColorProfile()
      return hydronium.h(ink.Box, { flexDirection = "row" },
        hydronium.h(ink.Text, { dimColor = not focus.isFocused() }, " / "),
        M.render(field_state, query.tokenize(field_state.text),
          { focused = focus.isFocused(), profile = profile }))
    end
  end
end

return M
