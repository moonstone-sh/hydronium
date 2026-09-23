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
| `spa` | **Not yet supported.** Reactive client routing now exists in `hydronium-router`; the remaining blocker is a complete server-less build and delivery recipe. |

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
- `-t, --template <VALUE>`: Application architecture (`ssr`, `islands`, `ink`, `love`).
- `--add-love`: Augment an existing LÖVE project. Initializes a LuaJIT 5.1 Moonstone environment when needed, adds Hydronium/Ballad, and installs `love-dev` and `love-package` without editing `main.lua`.
- `--minimal`: Generate the minimal plain-Lua starter. Cannot be combined with `--template`.
- `-n, --name <VALUE>`: Explicit project package name.
- `-i, --interpreter <VALUE>`: Lua runtime selection. LÖVE and Ink require `luajit@2.1`.
- `-f, --force`: Force file creation even if destination directory is non-empty.
- `--dry-run`: Output generated file paths without writing files.
