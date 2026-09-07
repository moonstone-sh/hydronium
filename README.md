# hydronium/create

Declarative scaffolding CLI tool for initializing new [Hydronium](https://moonstone.sh/packages/hydronium) reactive applications and components, built with [Clingy](https://moonstone.sh/packages/moonstone/clingy).

## Templates

| Template | Description |
| :--- | :--- |
| `ssr` (Default) | Full-stack server-side rendered application powered by Hydronium & Meteorite with reactive signal views. |
| `islands` | Zero-JS static layout with interactive client-hydrated component islands. |
| `spa` | Client-side reactive single page application. |
| `minimal` | Lightweight standalone reactive component for scripting and embedding. |

## Usage

```bash
# Scaffold in current directory with default SSR template
moon exec hydronium/create

# Scaffold in a target directory with a specific template
moon exec hydronium/create -- ./my-app --template ssr

# Preview generated file tree without writing to disk
moon exec hydronium/create -- ./my-app --template islands --dry-run
```

## Options

- `<DIRECTORY>`: Destination directory (defaults to `.`).
- `-t, --template <VALUE>`: Starter template (`ssr`, `islands`, `spa`, `minimal`).
- `-n, --name <VALUE>`: Explicit project package name.
- `-i, --interpreter <VALUE>`: Lua interpreter version (defaults to `lua@5.4`).
- `-f, --force`: Force file creation even if destination directory is non-empty.
- `--dry-run`: Output generated file paths without writing files.
