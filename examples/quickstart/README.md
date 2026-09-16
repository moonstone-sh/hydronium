# Hydronium Quickstart

The "try this first" example: a server-rendered Hydronium site with shared
browser/server routes, a progressive action, and a counter that runs as real
Lua in your browser. Component edits use state-preserving hot replacement.

Scaffolded from the `ssr` template (`hydronium/create`), then polished into
an onboarding page in the spirit of `npm create vite@latest`.

## Run it

```bash
moon sync      # resolve + materialize dependencies
moon run dev   # build the Meteorite server and serve on :8080
```

The first `moon run dev` compiles a native Zig server, so it takes a while.
When the server actually answers you get:

```
  ➜  Hydronium app up and running on http://localhost:8080/
```

Then open <http://localhost:8080/>.

The About link routes without reloading the browser Lua VM. The contact form
works as a native POST before hydration; after hydration it validates and
submits in place. `views/Site.lua` supplies both the Hydronium browser router
and Meteorite's explicit page routes. `views/Actions.lua` supplies the shared
form/server action contract.

To build a production binary instead:

```bash
moon run build
./dist/server
```

## Try state-preserving HMR

With `moon run dev` running:

1. Click the button a few times so it reads something like `Count: 3`.
2. Open `views/Counter.luax` and change `+ 2` to `+ 5`. Save.
3. The page does **not** reload. The counter still reads `Count: 3`, the
   button element is never remounted, and the next click makes it `Count: 8`.

Nothing in `views/Counter.luax` opts into that. Its state is an ordinary
`signals.createSignal(...)`; Hydronium's LUAX compiler rewrites it into the
descriptor the refresh registry matches on. Two conditions have to hold for
that rewrite to fire, and both are easy to break by accident:

- the setup function takes a parameter literally named `scope`;
- the signal is a two-name `local x, setX = ...` destructure at the setup
  function's **top level** -- not inside the returned render function, an
  `if`, or a loop.

Break either and nothing errors: that signal simply resets to its initial
value on each edit, exactly as it would have before this feature existed.

`views/App.luax` is also a hot boundary. Change its title or layout and the
counter state survives because the application root is refreshed inside the
same Lua VM. Stylesheets are replaced in place. Only `views/Document.luax` --
the equivalent of Vite's `index.html` -- is an explicit page-reload boundary.

## Layout

```
views/Document.luax       stable server document + client bootstrap
views/App.luax            hot client application root
views/Home.luax           hot home page, counter, and progressive form
views/About.luax          hot second page
views/Counter.luax        hot nested component with preserved signal state
views/Site.lua            shared serializable page declaration
views/Actions.lua         shared action declaration and schema
public/style.css          replaced in place without unloading the Lua VM
src/main.lua              Meteorite routes and explicit update policy
src/app/                  page adapter and action handler modules
src/views/Document.lua    compiles the document shell on demand
dev.sh                    startup banner, then `meteorite dev`
client_manifest.json      framework modules loaded by the browser VM
```

`views/*.luax` deliberately live at the project **root**, not under `src/`:
`meteorite dev` watches `src/` and restarts the server on any change there,
which would destroy the very page HMR exists to preserve.

Because this example lives inside the hydronium repo (at
`examples/quickstart`), its `moonstone.toml` uses in-repo relative path
dependencies (`../../core`, `../../luax`, `../../dom`) and a `../../../meteorite`
sibling checkout. A project scaffolded outside the repo gets the flat sibling
layout the template ships instead.
