-- Source-accessible DOM workbench: preview runs in an isolated browser VM.
local H = require("hydronium")
local Workbench = require("hydronium_lab.workbench").Workbench
local M = {}
local function option(value, text) return H.h("option", { value = value }, text) end
local Icon = require("hydronium_lab.workbench").Icon
local function menu(title, children)
  return H.h("details", { class = "hydronium-lab__toolbar-menu" },
    H.h("summary", nil, title), H.h("div", { class = "hydronium-lab__toolbar-panel" }, children))
end
local function widget(tag, role, defaults, children)
  return function(props)
    local attrs = {}
    for key, value in pairs(defaults or {}) do attrs[key] = value end
    for key, value in pairs(props) do if key ~= "children" then attrs[key] = value end end
    attrs["data-lab-" .. role] = ""
    return H.h(tag, attrs, (props.children and #props.children > 0) and props.children or children)
  end
end
M.ViewportPreset = widget("select", "viewport-preset", { ["aria-label"]="Viewport preset" })
M.ViewportWidth = widget("input", "viewport-width", {type="number", min=1, max=8192, ["aria-label"]="Viewport width"})
M.ViewportHeight = widget("input", "viewport-height", {type="number", min=1, max=8192, ["aria-label"]="Viewport height"})
M.SaveViewport = widget("button", "viewport-save", {type="button"}, "Save viewport")
-- Emulated inside the preview (prefers-color-scheme rules, matchMedia,
-- light-dark()); "page" follows the Lab page's own scheme.
M.ColorScheme = widget("select", "color-scheme", { ["aria-label"]="Preferred color scheme" }, {
  option("page", "Follow page"), option("light", "Light"), option("dark", "Dark") })
M.ColorSpace = widget("select", "color-space", { ["aria-label"]="Color authoring target" }, {
  option("srgb", "sRGB / RGB"), option("display-p3", "Display P3"), option("rec2020", "Rec. 2020") })
M.Vision = widget("select", "vision", { ["aria-label"]="Color vision simulation" }, {
  option("none", "Normal"), option("protanopia", "Protanopia approximation"), option("deuteranopia", "Deuteranopia approximation"), option("tritanopia", "Tritanopia approximation"), option("achromatopsia", "Grayscale") })
M.GamutSupport = widget("output", "gamut-support")
M.InkSize = widget("select", "ink-size", { ["aria-label"]="Terminal size preset" })
M.InkColor = widget("select", "ink-color", { ["aria-label"]="Terminal color capability" }, {
  option("ansi16", "ANSI 16"), option("ansi256", "ANSI 256"), option("truecolor", "Truecolor") })
M.RestartStory = widget("button", "dom-restart", {type="button", ["aria-label"]="Restart story", title="Restart story", class="hydronium-lab__toolbar-icon"}, H.h(Icon, {name="restart_alt"}))
function M.Preview(props)
  return H.h(widget("iframe", "dom-preview", {title="Hydronium DOM story", style="width:800px;height:600px;border:0;background:white"}), props)
end
function M.Root(props)
  local attrs = {}
  for key, value in pairs(props) do if key ~= "boot" then attrs[key] = value end end
  attrs.renderer = "dom"
  attrs["data-hydronium-dom-lab"] = ""
  attrs["data-lab-base-path"] = (props.boot or {}).base_path or "/__hydronium/lab"
  return H.h(require("hydronium_lab.components").Root, attrs, props.children)
end
function M.RendererControls()
  return H.h(H.Fragment, nil,
    H.h("span", { ["data-lab-dom-tools"]="" }, H.h(M.ViewportPreset),
      menu("Viewport", H.h(H.Fragment, nil, H.h("strong", nil, "Custom viewport"),
        H.h("label", nil, "Width", H.h(M.ViewportWidth)), H.h("label", nil, "Height", H.h(M.ViewportHeight)), H.h(M.SaveViewport))),
      menu("Color & vision", H.h(H.Fragment, nil,
        H.h("label", nil, "Color scheme", H.h(M.ColorScheme)), H.h("label", nil, "Color target", H.h(M.ColorSpace)), H.h("label", nil, "Vision", H.h(M.Vision)), H.h(M.GamutSupport)))),
    H.h("span", { ["data-lab-ink-tools"]="", class="hydronium-lab__ink-toolbar", hidden=true }, H.h(M.InkSize), H.h(M.InkColor)),
    H.h(M.RestartStory))
end
function M.Shell(props)
  local boot = props.boot or {}
  local options = {}
  for key, value in pairs(props) do options[key] = value end
  local defaults = {
    renderer = "dom", project_id = props.project_id, project_name = props.project_name,
    class = props.class, controls = props.controls, story_controls = props.story_controls,
    -- DOM time is the browser clock; never imply that arbitrary effects freeze.
    timeline = props.timeline,
    root_attributes = { ["data-hydronium-dom-lab"] = "", ["data-lab-base-path"] = boot.base_path or "/__hydronium/lab" },
    renderer_controls = props.renderer_controls or H.h(M.RendererControls),
    preview = props.preview or H.h(M.Preview),
    preferences = props.preferences,
  }
  for key, value in pairs(defaults) do if options[key] == nil then options[key] = value end end
  return H.h(Workbench, options)
end
function M.Document(props)
  local assets = props.boot.assets
  return H.h("html", { lang = "en" },
    H.h("head", nil, H.h("meta", { charset = "utf-8" }),
      H.h("meta", { name = "viewport", content = "width=device-width,initial-scale=1" }),
      H.h("title", nil, props.title or "Hydronium DOM Lab"),
      H.h("link", { rel = "stylesheet", href = assets.workbench_stylesheet })),
    H.h("body", {style="margin:0;width:100%;height:100dvh;overflow:hidden"}, H.h(props.shell or M.Shell, props), H.h("script", { type = "module", src = assets.client })))
end
return M
