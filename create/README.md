# hydronium/create

Declarative scaffolding CLI tool for initializing new [Hydronium](https://moonstone.sh/packages/hydronium) reactive applications and components, built with [Clingy](https://moonstone.sh/packages/moonstone/clingy).

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
# Install the generator
moon add hydronium/create

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

The terminal wizard renders inline, with the full form available through
Page Up/Page Down. Tab/Shift+Tab, Enter, arrows, `j`/`k`, and section jumps
`1`–`4` reveal the focused choice automatically. Letters and digits remain
ordinary input in the name and directory fields. Manual scrolling does not
change a choice; re-focusing a section brings its active field back into view.

Enter on Create, Ctrl+Enter, or Ctrl+S confirms. Confirmation disappears,
choices freeze, and tasks run. On completion, the wizard exits and leaves the
complete form and results in terminal scrollback as a receipt.
