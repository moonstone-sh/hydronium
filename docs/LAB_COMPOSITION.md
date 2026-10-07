# Composing Lab

The development candidate separates story state, renderer hosts and layout. These APIs require the next release.

## Default workbench

`hydronium_lab.workbench.Shell` composes the public exports of `hydronium_lab.components`. Its `layout` accepts `sidebar-right`, `sidebar-left` or `stacked`. Each slot accepts an element to replace its default, `false` to omit it, or `nil` to retain it. DOM and Ink document wrappers forward these options.

```lua
local H = require("hydronium")
local DOM = require("hydronium_lab.dom_document")
return function(props)
  local options = {}
  for key, value in pairs(props) do options[key] = value end
  options.layout = "sidebar-left"
  options.rulers, options.ruler_handle, options.hints = false, false, false
  return H.h(DOM.Document, options)
end
```

Set `document = "Workbench"` in `hydronium.lab.lua`, and put this module in a configured `module_roots` directory. The existing host supplies its boot contract. `hydronium-lab customize` creates a document wrapper for you.

Slots include `canvas`, `toolbar`, `canvas_actions`, `stage`, `grid`, `rulers`, `guides`, `ruler_handle`, `hints`, `status`, `sidebar`, `sidebar_header`, `story_search`, `catalog`, `inspector`, `controls`, `timeline`, `interactions`, `preferences_panel`, `navigation_settings` and `grid_settings`. Existing `preview`, `renderer_controls`, `metrics`, `story_controls` and `preferences` slots remain available.

## Own the arrangement

Use `Root` to choose ordering and CSS. It has no default workbench arrangement. `DOM.Root` supplies DOM/mixed host attributes, and `DOM.Preview` supplies the isolated iframe.

```lua
local H = require("hydronium")
local C = require("hydronium_lab.components")
local DOM = require("hydronium_lab.dom_document")
local function MyShell(props)
  return H.h(DOM.Root, {
    boot = props.boot, project_id = props.project_id,
    style = "display:flex;flex-direction:column;height:100dvh",
  },
    H.h(C.Toolbar, nil, H.h(C.ActiveStory), H.h(DOM.ViewportPreset)),
    H.h(C.Canvas, nil, H.h(C.Stage, nil,
      H.h(C.Viewport, nil, H.h(C.Grid), H.h(DOM.Preview)),
      H.h(C.Rulers), H.h(C.Guides), H.h(C.RulerHandle))),
    H.h(C.StoryCatalog))
end
return function(props)
  local options = {}
  for key, value in pairs(props) do options[key] = value end
  options.shell = MyShell
  return H.h(DOM.Document, options)
end
```

The component stylesheet scopes its selectors and tokens to `.hydronium-lab`; it does not set the embedding page's HTML/body layout. The standalone document sets its own body dimensions. Components accept `class`, `style` and ordinary attributes; `unstyled = true` omits default component classes. Preserve `data-lab-*` roles when supplying your own markup.

| Surface | Components |
| --- | --- |
| Layout | Root, Canvas, Toolbar, Hud, CanvasActions, Sidebar, SidebarHeader |
| Canvas | Stage, Viewport, Grid, Rulers, Guides, Guide, RulerHandle, Hints, Status |
| Stories | ActiveStory, StorySearch, StoryCatalog, Inspector, Interactions |
| Settings | Preferences, PreferencesHeader, NavigationSettings, GridSettings |
| Actions | ZoomIn, ZoomOut, CenterCanvas, SidebarToggle, PreferencesToggle, PreferencesClose |
| Args/playback | All exports of hydronium_lab.controls |
| DOM/mixed adapter | Root, Preview, ViewportPreset, ViewportWidth, ViewportHeight, SaveViewport, ColorScheme, ColorSpace, Vision, GamutSupport, InkSize, InkColor, RestartStory from hydronium_lab.dom_document |
| Ink adapter | Shell, InkControls, InkPreferences, Document from hydronium_ink_lab.components |

Settings groups are convenient compositions. For a different arrangement, supply ordinary bound inputs using the roles in their component source. `Guide` uses `guide_id` to identify its model. The browser guide installer accepts `createGuide(model, document)` to customize generated guide buttons.

## Behaviour and lifecycle

A renderer needs its preview surface. Catalog, search, status, toolbar, settings and canvas decoration are optional.

`installCanvasGuides` binds existing ruler and guide components; it never inserts missing layers. Disposal removes generated guide buttons and listeners while retaining component-owned layers.

`installPreviewCanvas` lives in Lab's `workbench.js`. It exposes `reset`, `fit`, `resize`, `refresh`, `getSnapshot`, `zoomTo`, `panTo` and `destroy`. DOM/mixed `createDomLab` exposes observable story state and selection. Custom widgets use these APIs rather than duplicating state or transport.

Shortcuts belong to the focused Lab. Use distinct `project_id` values for independent persisted preferences. DOM keeps its browser clock; Ink keeps virtual playback.

Meteorite's HTTP adapter still supports one Lab prefix per process. Multiple browser roots may share that host. Independent server registries under multiple prefixes remain a host limitation.

## Ballad integration

`hydronium_ballad.plugins.lab` adapts the CLI's existing discovery and host planner. It requires the same development dependencies as `hydronium-lab dev`, plus `hydronium/ballad` and an explicit `moonstone/ballad` tool dependency. It projects the installed Lab CLI planner into Ballad's isolated tool scope; no source checkout paths are needed. The lower-level planner adapter is `hydronium_lab_cli.ballad`.

```lua
local ballad = require("ballad")
return ballad.partiture(function(p)
  local lab = p:use(require("hydronium_ballad.plugins.lab"))
  local files = lab.prepare({ config_path = "hydronium.lab.lua" })
  p.sink.directory(files, { out = ".hydronium/lab" })
end)
```

Use a dedicated generated directory: Ballad replaces directory outputs. Never use the project root as the sink. If changing `state_dir`, use that same path for the sink. `prepare` accepts a config table, host and port. Asset metadata records the host adapter, command and environment.

The build prepares files without starting a persistent server. `hydronium-lab dev` owns launch/watch lifecycle; another orchestrator can consume the same host plan. Runtime routes remain owned by `hydronium_meteorite.lab.mount`.
