--[[
  Color PROFILE: hydronium_ink.color.profile/by_profile/resolve_by_profile,
  the hydronium_ink.hooks.useColorProfile() hook, Session:colorProfile()/
  setColorProfile(), and ink.byProfile/ink.adaptive actually changing what
  paints. See hydronium_ink.color's own top doc comment for the full design
  (why this is a SEPARATE axis from `_colorCapability`/`terminalColor.capability`).
--]]

local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert

local H = require("hydronium")
local ink = require("hydronium_ink")
local ink_color = require("hydronium_ink.color")
local hooks = require("hydronium_ink.hooks")
local session = require("hydronium_ink.session")

describe("hydronium_ink.color -- M.profile (color profile detection)", function()
  it("returns an explicit value unchanged, bypassing detection entirely", function()
    assert.equal(ink_color.profile("truecolor"), "truecolor")
    assert.equal(ink_color.profile("ansi256"), "ansi256")
    assert.equal(ink_color.profile("ansi16"), "ansi16")
    assert.equal(ink_color.profile("none"), "none")
  end)

  it("rejects an unsupported explicit value rather than guessing", function()
    assert.falsy(pcall(ink_color.profile, "bogus"))
  end)

  it("honors NO_COLOR (present, regardless of its value) over positive auto-detection signals", function()
    local function getenv(name)
      if name == "NO_COLOR" then return "" end -- presence alone is the rule, even empty
      if name == "COLORTERM" then return "truecolor" end
      return nil
    end
    assert.equal(ink_color.profile("auto", getenv), "none")
    assert.equal(ink_color.profile(nil, getenv), "none")
  end)

  it("falls back to real capability auto-detection when neither NO_COLOR nor FORCE_COLOR is set", function()
    local function getenv(name)
      if name == "COLORTERM" then return "truecolor" end
      return nil
    end
    assert.equal(ink_color.profile("auto", getenv), "truecolor")

    local function getenv256(name)
      if name == "TERM" then return "xterm-256color" end
      return nil
    end
    assert.equal(ink_color.profile("auto", getenv256), "ansi256")

    assert.equal(ink_color.profile("auto", function() return nil end), "ansi16")
  end)

  it("maps FORCE_COLOR=0/1/2/3 to none/ansi16/ansi256/truecolor", function()
    local function getenv_for(value)
      return function(name) if name == "FORCE_COLOR" then return value end return nil end
    end
    assert.equal(ink_color.profile("auto", getenv_for("0")), "none")
    assert.equal(ink_color.profile("auto", getenv_for("1")), "ansi16")
    assert.equal(ink_color.profile("auto", getenv_for("2")), "ansi256")
    assert.equal(ink_color.profile("auto", getenv_for("3")), "truecolor")
    assert.equal(ink_color.profile("auto", getenv_for("true")), "truecolor")
  end)

  it("FORCE_COLOR wins over NO_COLOR -- the more specific, explicit request", function()
    local function getenv(name)
      if name == "FORCE_COLOR" then return "3" end
      if name == "NO_COLOR" then return "1" end
      return nil
    end
    assert.equal(ink_color.profile("auto", getenv), "truecolor")
  end)
end)

describe("hydronium_ink.color -- by_profile / resolve_by_profile fallback chain", function()
  it("marks a value so is_by_profile recognizes it, and only it", function()
    local marker = ink_color.by_profile({ truecolor = "a" })
    assert.truthy(ink_color.is_by_profile(marker))
    assert.falsy(ink_color.is_by_profile("a"))
    assert.falsy(ink_color.is_by_profile({ truecolor = "a" }))
    assert.falsy(ink_color.is_by_profile(nil))
  end)

  it("errors on an unknown profile key rather than silently never matching it", function()
    assert.falsy(pcall(ink_color.by_profile, { trueColor = "a" }))
    assert.falsy(pcall(ink_color.by_profile, { ansi_16 = "a" }))
  end)

  it("resolves an exact profile match first", function()
    local marker = ink_color.by_profile({ truecolor = "a", ansi16 = "b", none = "c" })
    local value, present = ink_color.resolve_by_profile(marker, "ansi16")
    assert.equal(value, "b")
    assert.truthy(present)
  end)

  it("falls back to the NEAREST richer defined entry when the exact one is missing", function()
    local marker = ink_color.by_profile({ truecolor = "richest", ansi256 = "nearer" })
    local value, present = ink_color.resolve_by_profile(marker, "ansi16")
    assert.equal(value, "nearer") -- ansi256 is nearer to ansi16 than truecolor is
    assert.truthy(present)

    local onlyRich = ink_color.by_profile({ truecolor = "only" })
    local v2 = ink_color.resolve_by_profile(onlyRich, "none")
    assert.equal(v2, "only")
  end)

  it("never falls back to a PLAINER entry, only a richer one", function()
    local marker = ink_color.by_profile({ ansi16 = "plain", none = "plainer" })
    local value, present = ink_color.resolve_by_profile(marker, "truecolor")
    assert.equal(value, nil)
    assert.falsy(present)
  end)

  it("resolves to absent (nil, false) when only a plainer-or-equal entry exists", function()
    local marker = ink_color.by_profile({ none = "plainest" })
    local value, present = ink_color.resolve_by_profile(marker, "ansi16")
    -- "ansi16" has no own entry, and "none" is PLAINER than ansi16, not richer.
    assert.equal(value, nil)
    assert.falsy(present)
  end)

  it("the generic resolver (structural props) still inherits ansi16 under \"none\" -- ansi16 IS richer than none", function()
    local marker = ink_color.by_profile({ ansi16 = "x" })
    local value, present = ink_color.resolve_by_profile(marker, "none")
    assert.equal(value, "x")
    assert.truthy(present)
  end)
end)

describe("hydronium_ink.color -- resolve_by_profile_color's \"none\" special case", function()
  it("strips to (nil, true) at \"none\" when no explicit 'none' entry is given, even with richer entries defined", function()
    -- Unlike the generic resolver above: a COLOR must not keep painting a
    -- real color under NO_COLOR/colorProfile="none" just because a richer
    -- profile happened to define one -- that would defeat the whole point
    -- of exposing "none" to color-aware props.
    local marker = ink_color.by_profile({ truecolor = "#ff0000", ansi16 = "cyan" })
    local value, present = ink_color.resolve_by_profile_color(marker, "none")
    assert.equal(value, nil)
    assert.truthy(present)
  end)

  it("still honors an explicit 'none' entry when one is given", function()
    local marker = ink_color.by_profile({ truecolor = "#ff0000", none = "white" })
    local value, present = ink_color.resolve_by_profile_color(marker, "none")
    assert.equal(value, "white")
    assert.truthy(present)
  end)

  it("behaves exactly like the generic resolver at every OTHER profile", function()
    local marker = ink_color.by_profile({ truecolor = "richest", ansi256 = "nearer" })
    local value, present = ink_color.resolve_by_profile_color(marker, "ansi16")
    assert.equal(value, "nearer")
    assert.truthy(present)
  end)
end)

describe("hydronium_ink.session / hooks.useColorProfile -- override and reactivity", function()
  it("defaults to a real detected profile when no colorProfile option is given", function()
    local s = session.create(H.h(ink.Box, {}), { columns = 10, rows = 1 })
    local profile = s:colorProfile()
    assert.truthy(profile == "truecolor" or profile == "ansi256" or profile == "ansi16" or profile == "none",
      "unexpected default profile: " .. tostring(profile))
    s:close()
  end)

  it("honors an explicit colorProfile session option, independent of `color`", function()
    local s = session.create(H.h(ink.Box, {}), { columns = 10, rows = 1, color = "truecolor", colorProfile = "none" })
    assert.equal(s:colorProfile(), "none")
    assert.equal(s:colorCapability(), "truecolor") -- unaffected -- separate axis
    s:close()
  end)

  it("useColorProfile() reads the session's profile from inside a mounted component", function()
    local seen
    local function Probe()
      return function()
        seen = hooks.useColorProfile()
        return H.h(ink.Text, {}, "x")
      end
    end
    local s = session.create(H.h(Probe, {}), { columns = 10, rows = 1, colorProfile = "ansi16" })
    assert.equal(seen, "ansi16")
    s:close()
  end)

  it("Session:setColorProfile() changes what useColorProfile() reads on the very next render", function()
    local seen
    local function Probe()
      return function()
        seen = hooks.useColorProfile()
        return H.h(ink.Text, {}, "x")
      end
    end
    local s = session.create(H.h(Probe, {}), { columns = 10, rows = 1, colorProfile = "truecolor" })
    assert.equal(seen, "truecolor")
    s:setColorProfile("none")
    assert.equal(seen, "none")
    assert.equal(s:colorProfile(), "none")
    s:close()
  end)

  it("useColorProfile() errors outside a mounted component tree, like every other hook here", function()
    assert.falsy(pcall(hooks.useColorProfile))
  end)
end)

describe("hydronium_ink -- ink.byProfile/ink.adaptive actually change what paints", function()
  it("resolves a color prop per the live session profile", function()
    local element = H.h(ink.Text, {
      color = ink.byProfile({ truecolor = "#ff0000", ansi16 = "cyan" }),
    }, "x")

    local truecolorSession = session.create(element, { columns = 5, rows = 1, colorProfile = "truecolor" })
    local truecolorCell = truecolorSession:frame().rows[1][1]
    assert.equal(truecolorCell.fg.kind, "rgb")
    assert.equal(truecolorCell.fg.r, 255)
    truecolorSession:close()

    local ansi16Session = session.create(element, { columns = 5, rows = 1, colorProfile = "ansi16" })
    local ansi16Cell = ansi16Session:frame().rows[1][1]
    assert.equal(ansi16Cell.fg.kind, "palette")
    ansi16Session:close()
  end)

  it("strips a color under \"none\" when no explicit 'none' entry is given, leaving other style props alone", function()
    local element = H.h(ink.Text, {
      color = ink.adaptive({ truecolor = "#ff0000" }),
      inverse = true,
    }, "x")
    local s = session.create(element, { columns = 5, rows = 1, colorProfile = "none" })
    local cell = s:frame().rows[1][1]
    assert.equal(cell.fg, nil)
    assert.truthy(cell.inverse)
    s:close()
  end)

  it("resolves a structural (non-color) prop -- inverse/bold -- per profile too", function()
    local element = H.h(ink.Text, {
      inverse = ink.byProfile({ truecolor = false, none = true }),
    }, "x")
    local truecolorSession = session.create(element, { columns = 5, rows = 1, colorProfile = "truecolor" })
    assert.falsy(truecolorSession:frame().rows[1][1].inverse)
    truecolorSession:close()

    local noneSession = session.create(element, { columns = 5, rows = 1, colorProfile = "none" })
    assert.truthy(noneSession:frame().rows[1][1].inverse)
    noneSession:close()
  end)

  it("live-updates a cached Text node's painted style when the profile changes at runtime", function()
    -- Guards against the caching trap this feature has to work around:
    -- a Text node's resolved style is normally cached across paints keyed
    -- only on its OWN prop/dirty state (see host/terminal.lua's
    -- buildYogaTree) -- a byProfile-using node must ALSO recompute when
    -- nothing about its own props changed but the session's color profile
    -- did (host.setColorProfile's `isProfileStale` check).
    local element = H.h(ink.Text, {
      color = ink.byProfile({ truecolor = "#00ff00", ansi16 = "cyan" }),
    }, "x")
    local s = session.create(element, { columns = 5, rows = 1, colorProfile = "truecolor" })
    assert.equal(s:frame().rows[1][1].fg.kind, "rgb")
    s:setColorProfile("ansi16")
    assert.equal(s:frame().rows[1][1].fg.kind, "palette")
    s:setColorProfile("truecolor")
    assert.equal(s:frame().rows[1][1].fg.kind, "rgb")
    s:close()
  end)

  it("does not affect a plain (non-adaptive) color prop under any profile -- unchanged default behavior", function()
    local element = H.h(ink.Text, { color = "#ff0000" }, "x")
    for _, profile in ipairs({ "truecolor", "ansi256", "ansi16", "none" }) do
      local s = session.create(element, { columns = 5, rows = 1, colorProfile = profile })
      local cell = s:frame().rows[1][1]
      assert.equal(cell.fg.kind, "rgb")
      assert.equal(cell.fg.r, 255)
      s:close()
    end
  end)
end)
