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
function M.RendererControls()
  return H.h(H.Fragment, nil,
    H.h("span", { ["data-lab-dom-tools"] = "" },
      H.h("select", { ["data-lab-viewport-preset"] = "", ["aria-label"] = "Viewport preset" }),
      menu("Viewport", H.h(H.Fragment, nil,
        H.h("strong", nil, "Custom viewport"),
        H.h("label", nil, "Width", H.h("input", { type = "number", min = 1, max = 8192, ["data-lab-viewport-width"] = "", ["aria-label"] = "Viewport width" })),
        H.h("label", nil, "Height", H.h("input", { type = "number", min = 1, max = 8192, ["data-lab-viewport-height"] = "", ["aria-label"] = "Viewport height" })),
        H.h("button", { type = "button", ["data-lab-viewport-save"] = "" }, "Save viewport"))),
      menu("Color & vision", H.h(H.Fragment, nil,
        H.h("label", nil, "Color target", H.h("select", { ["data-lab-color-space"] = "", ["aria-label"] = "Color authoring target" }, option("srgb", "sRGB / RGB"), option("display-p3", "Display P3"), option("rec2020", "Rec. 2020"))),
        H.h("label", nil, "Vision", H.h("select", { ["data-lab-vision"] = "", ["aria-label"] = "Color vision simulation" }, option("none", "Normal"), option("protanopia", "Protanopia approximation"), option("deuteranopia", "Deuteranopia approximation"), option("tritanopia", "Tritanopia approximation"), option("achromatopsia", "Grayscale"))),
        H.h("output", { ["data-lab-gamut-support"] = "" })))),
    H.h("span", { ["data-lab-ink-tools"] = "", class = "hydronium-lab__ink-toolbar", hidden = true },
      H.h("select", { ["data-lab-ink-size"] = "", ["aria-label"] = "Terminal size preset" }),
      H.h("select", { ["data-lab-ink-color"] = "", ["aria-label"] = "Terminal color capability" }, option("ansi16", "ANSI 16"), option("ansi256", "ANSI 256"), option("truecolor", "Truecolor"))),
    H.h("button", { type = "button", ["data-lab-dom-restart"] = "", ["aria-label"] = "Restart story", title = "Restart story", class = "hydronium-lab__toolbar-icon" }, H.h(Icon, { name = "restart_alt" })))
end
function M.Shell(props)
  local boot = props.boot or {}
  return H.h(Workbench, {
    renderer = "dom", project_id = props.project_id, project_name = props.project_name,
    class = props.class, controls = props.controls, story_controls = props.story_controls,
    -- DOM time is the browser clock; never imply that arbitrary effects freeze.
    timeline = props.timeline,
    root_attributes = { ["data-hydronium-dom-lab"] = "", ["data-lab-base-path"] = boot.base_path or "/__hydronium/lab" },
    renderer_controls = props.renderer_controls or H.h(M.RendererControls),
    preview = props.preview or H.h("iframe", { ["data-lab-dom-preview"] = "", title = "Hydronium DOM story", style = "width:800px;height:600px;border:0;background:white" }),
    preferences = props.preferences,
  })
end
function M.Document(props)
  local assets = props.boot.assets
  return H.h("html", { lang = "en" },
    H.h("head", nil, H.h("meta", { charset = "utf-8" }),
      H.h("meta", { name = "viewport", content = "width=device-width,initial-scale=1" }),
      H.h("title", nil, props.title or "Hydronium DOM Lab"),
      H.h("link", { rel = "stylesheet", href = assets.workbench_stylesheet })),
    H.h("body", nil, H.h(M.Shell, props), H.h("script", { type = "module", src = assets.client })))
end
return M
