# hydronium/create

Declarative scaffolding CLI tool for initializing new [Hydronium](https://moonstone.sh/packages/hydronium) reactive applications and components, built with [Clingy](https://moonstone.sh/packages/moonstone/clingy).

## Templates

| Template | Description |
| :--- | :--- |
| `ssr` (Default) | Full-stack server-side rendered application powered by Hydronium & Meteorite with reactive signal views. |
| `islands` | Mostly-static SSR shell with one real, client-hydrated JS island (server-rendered button, client-side click handling). |
| `minimal` | Lightweight standalone reactive component for scripting and embedding. |
| `spa` | **Not yet supported.** Hydronium has no client-side mount API, bundler, or CLI binary today; `--template spa` returns a clear error instead of generating broken output. See `src/create/templates/spa.lua`'s own comment for what would need to exist first. |

## Usage

```bash
# Install the generator
moon add hydronium/create

# Scaffold in current directory with default SSR template
moon exec hydronium-create

# Scaffold in a target directory with a specific template
moon exec hydronium-create -- ./my-app --template ssr

# Preview generated file tree without writing to disk
moon exec hydronium-create -- ./my-app --template islands --dry-run
```

## Options

- `<DIRECTORY>`: Destination directory (defaults to `.`).
- `-t, --template <VALUE>`: Starter template (`ssr`, `islands`, `minimal`).
- `-n, --name <VALUE>`: Explicit project package name.
- `-i, --interpreter <VALUE>`: Lua interpreter version (defaults to `lua@5.4`).
- `-f, --force`: Force file creation even if destination directory is non-empty.
- `--dry-run`: Output generated file paths without writing files.
