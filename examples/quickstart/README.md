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

Then open <http://localhost:8080/>. Set `PORT` to use another port
(`PORT=8081 moon run dev`).

The About link routes without reloading the browser Lua VM. The contact form
works as a native POST before hydration; after hydration it validates and
submits in place. `src/views/Site.lua` supplies both the Hydronium browser
router and Meteorite's explicit page routes. `src/views/Actions.lua` supplies
the shared form/server action contract. <http://localhost:8080/hello/Ada> is a
plain Meteorite route whose handler renders a Hydronium component.

## How the server is put together

Meteorite owns HTTP. `src/main.lua` is an ordinary Meteorite app:

```lua
hydronium.mount(app)                     -- framework routes: runtime, HMR, dev modules
router.mount(app, site, { ... })         -- one GET per page in src/views/Site.lua
app:get("/hello/:name", ..., meteorite.lua("app.hello", ...)) -- your own routes
app:get("/api/health", ..., function(c) return c:json({ status = "ok" }) end)
```

`src/app/hello.lua` renders `src/features/greeting/Greeting.luax`.
Components can live anywhere on the Lua path. See
[ECOSYSTEM_BOUNDARIES.md](../../docs/ECOSYSTEM_BOUNDARIES.md) for how
Hydronium, Meteorite, Ballad and Vite divide the work.

To build a production binary instead:

```bash
moon run build
./dist/server
```

`moon run build` first runs `build.partiture.lua` (Ballad): source discovery
plus one content-hashed browser chunk in `.hydronium/client/`. The release
server serves that chunk, and the page loads the whole app in one request
instead of one request per module. `moon run dev` never uses it.

## Try state-preserving HMR

With `moon run dev` running:

1. Click the button a few times so it reads something like `Count: 3`.
2. Open `src/views/Counter.luax` and change `+ 2` to `+ 5`. Save.
3. The page does **not** reload. The counter still reads `Count: 3`, the
   button element is never remounted, and the next click makes it `Count: 8`.

Nothing in `src/views/Counter.luax` opts into that. Its state is an ordinary
`signals.createSignal(...)`; Hydronium's LUAX compiler rewrites it into the
descriptor the refresh registry matches on. Two conditions have to hold for
that rewrite to fire, and both are easy to break by accident:

- the setup function takes a parameter literally named `scope`;
- the signal is a two-name `local x, setX = ...` destructure at the setup
  function's **top level** -- not inside the returned render function, an
  `if`, or a loop.

Break either and nothing errors: that signal simply resets to its initial
value on each edit, exactly as it would have before this feature existed.

`src/views/App.luax` is also a hot boundary. Change its title or layout and
the counter state survives because the application root is refreshed inside
the same Lua VM. Only `src/views/Document.luax` -- the equivalent of Vite's
`index.html` -- is an explicit page-reload boundary.

`public/style.css` is listed under `watch` in `hydronium.sources.lua` with its
URL, so the browser swaps the stylesheet in place, without unloading the Lua
VM. In development `hydronium.mount` serves that URL from disk, and the server
does not rebuild for it. That's also why `mount` comes before `meteorite.site`
in `src/main.lua`: Meteorite matches routes in declaration order.

## Layout

```
src/main.lua                      Meteorite app: framework mount, pages, your routes
src/app/page_handler.lua          renders router pages inside views/Document.luax
src/app/action_handler.lua        form/server actions
src/app/hello.lua                 plain Meteorite route rendering a component
src/features/greeting/            a server-only component outside views/
src/views/Document.luax           stable server document + client bootstrap
src/views/App.luax                hot client application root
src/views/Home.luax, About.luax   hot pages, counter, progressive form
src/views/Counter.luax            hot nested component with preserved signal state
src/views/Site.lua                shared serializable page declaration
src/views/Actions.lua             shared action declaration and schema
hydronium.sources.lua             module topology + watched files (HMR authority)
public/style.css                  stylesheet
dev.sh                            startup banner, then `meteorite dev`
```

Hot modules may sit under `src/`: `hydronium.dev_watch()` marks every `hot`
module in `hydronium.sources.lua` as passive, so editing one never restarts
the server.

Because this example lives inside the hydronium repo, its `moonstone.toml`
uses in-repo path dependencies (`../../core`, `../../luax`, `../../dom`,
`../../router`) and Meteorite from the registry. A project scaffolded with
`hydronium/create` uses registry packages throughout.
