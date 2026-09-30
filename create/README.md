# hydronium/create

Declarative scaffolding CLI tool for initializing new [Hydronium](https://moonstone.sh/packages/hydronium) reactive applications and components, built with [Clingy](https://moonstone.sh/packages/moonstone/clingy).

## Create and run a browser app

You need Moonstone, Bun and the native build prerequisites for Meteorite.
In an empty tooling directory:

```sh
moon init . --name app-tools --interpreter luajit@2.1
moon add --tool hydronium/create
moon exec -- hydronium-create ./my-app --template ssr --package-manager bun --tailwind
cd my-app
moon sync
bun install
bun run dev
```

Open the URL printed by dev, normally http://localhost:8080/. Click the counter,
edit views/Counter.luax and save: eligible component state survives the update.
CSS changes update in place. The document bootstrap is a page-reload boundary.
The selected package manager controls install, dev and build helper commands.

```sh
bun run build
./dist/server
```

The build produces the application in dist, including its server and browser
assets. Stop the development process before starting the release server if
both use the same port. Use --dry-run to inspect generated files before writing;
use --minimal for a one-shot HTML program without a live HMR process.

## Templates

| Template | Description |
| :--- | :--- |
| `ssr` (Default) | Meteorite SSR app with a shared Hydronium route manifest, progressive actions, a persistent browser Lua VM, state-preserving component HMR, and in-place CSS updates. |
| `islands` | Mostly-static SSR shell with one real, client-hydrated JS island (server-rendered button, client-side click handling). |
| `--minimal` | One-shot plain-Lua server rendering for scripting and embedding. It exits after printing HTML, so it intentionally has no HMR process. |
| `ink` | Interactive terminal counter with state-preserving LUAX HMR, Yoga layout, keyboard input, and a ready-to-run browser Component Lab. Requires LuaJIT 2.1 on macOS or glibc Linux. |
| `love` | LÖVE 11.5 game with frame-boundary HMR and a dependency-closed `.love` packaging pipeline. LÖVE itself is a host prerequisite. |
| `spa` | Client-only app with a Ballad-bundled Lua entry and Vite-built assets. Uses Hydronium routing by default; `--router meteorite` selects server-backed delivery. |

The SSR template is the complete browser example. `views/Site.lua` owns page
ids, paths, and component module ids. Hydronium Router uses it in the browser;
the Meteorite adapter lowers it to explicit server routes. `views/Actions.lua`
defines shared action descriptors, and `src/app/contact_action.lua` handles the
same action as JSON-enhanced or native HTML form submission.

## Usage

```bash
# Install the generator as a tool
moon add --tool hydronium/create

# Scaffold in current directory with default SSR template
moon exec -- hydronium-create

# Scaffold in a target directory with a specific template
moon exec -- hydronium-create ./my-app --template ssr

# Preview generated file tree without writing to disk
moon exec -- hydronium-create ./my-app --template islands --dry-run

# Create an interactive terminal app
moon exec -- hydronium-create ./my-terminal-app --template ink

# Create a new Moonstone-provisioned LÖVE game
moon exec -- hydronium-create ./my-game --template love

# Add Hydronium to an existing LÖVE game without replacing main.lua
moon exec -- hydronium-create --add-love ./existing-game

# Create the smallest plain-Lua Hydronium project
moon exec -- hydronium-create ./my-component --minimal
```

## Options

- `<DIRECTORY>`: Destination directory (defaults to `.`).
- `-t, --template <VALUE>`: Application architecture (`ssr`, `spa`, `islands`, `ink`, `love`).
- `--router <VALUE>`: Select `hydronium` or `meteorite` routing for supported browser templates.
- `--tailwind`: Add Tailwind CSS v4 to an SSR, SPA or islands project.
- `--package-manager <VALUE>`: Select `bun`, `pnpm` or `npm` for browser tooling.
- `--add-love`: Augment an existing LÖVE project. Initializes a LuaJIT 5.1 Moonstone environment when needed, adds Hydronium/Ballad, and installs `love-dev` and `love-package` without editing `main.lua`.
- `--minimal`: Generate the minimal plain-Lua starter. Cannot be combined with `--template`.
- `-n, --name <VALUE>`: Explicit project package name.
- `-i, --interpreter <VALUE>`: Lua runtime selection. LÖVE and Ink require `luajit@2.1`.
- `-f, --force`: Force file creation even if destination directory is non-empty.
- `--dry-run`: Output generated file paths without writing files.


## Package managers and interactive form

For SSR, SPA and islands, `--package-manager bun|pnpm|npm` selects the install
command, generated Moonstone scripts, development Vite runner, and README
commands. Bun templates also run their JavaScript helper scripts with Bun.
Tailwind uses the same selected manager. For example:

```sh
moon exec -- hydronium-create ./my-app --template ssr --package-manager bun --tailwind
cd my-app
moon sync
bun install
bun run dev
```

SSR and islands use the Hydronium CLI to coordinate Meteorite and Vite.
App components hydrate inside one browser Lua VM; LUAX edits preserve eligible
component state and CSS updates in place. The document bootstrap remains a
reload boundary. The LUAX require loader is installed at VM entry points, so
views do not each need compilation shims.

The inline wizard walks through Project, App, Flavour, Features, Tooling, and Review.
Flavour is a separate follow-up page for apps with routing variants.
Irrelevant pages are skipped. Arrows and `j`/`k` move focus; Space or Enter
selects a choice. Tab/Shift+Tab move between fields. Activate Continue to advance,
or use Back/Esc to return with your answers intact. Outside text fields,
`1`–`6` jump to the numbered steps available for your app. Ctrl+S opens Review; only Create project accepts it.

Two footer lines summarize your choices and navigation. Wide terminals show
**Fizzing**, a centered proton-transfer diorama with fixed arrow and product
positions. Molecules illuminate from gray using universal-indicator-inspired
acid/base colors; these illustrate chemical roles rather than measured pH. Compact and short terminals prioritize the current question.
Set `HYDRONIUM_REDUCED_MOTION=1` to keep Fizzing still.

After acceptance, editing controls disappear and installation progress replaces
the wizard. The final receipt remains in terminal scrollback with the chosen
settings, individual task results, and commands to continue.
