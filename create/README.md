# moonstone/hydronium-create

Declarative scaffolding CLI tool for initializing new [Hydronium](https://moonstone.sh/packages/hydronium) reactive applications and components, built with [Clingy](https://moonstone.sh/packages/moonstone/clingy).

## Templates

| Template | Description |
| :--- | :--- |
| `ssr` (Default) | Meteorite SSR shell with a persistent browser Lua VM, state-preserving component HMR, and in-place CSS updates. |
| `islands` | Mostly-static SSR shell with one real, client-hydrated JS island (server-rendered button, client-side click handling). |
| `--minimal` | One-shot plain-Lua server rendering for scripting and embedding. It exits after printing HTML, so it intentionally has no HMR process. |
| `ink` | Interactive terminal counter with state-preserving LUAX HMR, Yoga layout, and keyboard input. Requires LuaJIT 2.1 on macOS or glibc Linux. |
| `spa` | **Not yet supported.** Reactive client routing now exists in `hydronium-router`; the remaining blocker is a complete server-less build and delivery recipe. |

## Usage

```bash
# Install the generator
moon add moonstone/hydronium-create

# Scaffold in current directory with default SSR template
moon exec hydronium-create

# Scaffold in a target directory with a specific template
moon exec hydronium-create -- ./my-app --template ssr

# Preview generated file tree without writing to disk
moon exec hydronium-create -- ./my-app --template islands --dry-run

# Create an interactive terminal app
moon exec hydronium-create -- ./my-terminal-app --template ink

# Create the smallest plain-Lua Hydronium project
moon exec hydronium-create -- ./my-component --minimal
```

## Options

- `<DIRECTORY>`: Destination directory (defaults to `.`).
- `-t, --template <VALUE>`: Application architecture (`ssr`, `islands`, `ink`).
- `--minimal`: Generate the minimal plain-Lua starter. Cannot be combined with `--template`.
- `-n, --name <VALUE>`: Explicit project package name.
- `-i, --interpreter <VALUE>`: Lua interpreter version (defaults to `luajit@2.1`). The `ink` template only supports LuaJIT 2.1.
- `-f, --force`: Force file creation even if destination directory is non-empty.
- `--dry-run`: Output generated file paths without writing files.
