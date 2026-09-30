# Hydronium Lab CLI

`hydronium-lab` discovers `*.stories.lua`, `*.stories.luax`, `*.stories.md`, and `*.stories.mdx` files, then
hands a deterministic launch plan to an explicit host adapter.

```sh
moon add --tool hydronium/lab-cli
moon exec -- hydronium-lab init
moon run lab
```

`init` is safe to rerun. It installs only the renderer and host packages in
the `dev` profile, the Meteorite executable in the `tool` profile, and never
adds `hydronium/lab-cli` a second time: that tool is the command already
running the setup.

The default `meteorite` adapter is supplied by `hydronium/meteorite`. A custom
adapter may be selected explicitly in `hydronium.lab.lua`:

```lua
return {
  roots = { "src" },
  host = {
    package = "acme/lab-host",
    module = "acme_lab_host",
  },
  base_path = "/tools/components",
}
```

The adapter module exposes `plan(input)` and returns `{ files, command, url }`.
Moonstone supplies the explicitly named package root to the tool scope. There
is no ambient plugin scanning: the project names the package and module it
trusts.

The default setup keeps `hydronium/lab`, the renderer, and its host adapter in
the development dependency graph. Only the launcher and the selected host
executable use the tool role. Therefore Lab does not enter the application's
production runtime closure merely because it is installed.

Live controls, virtual playback and optional project-owned workbenches are documented in [Lab controls](../docs/LAB_CONTROLS.md).

## Own the workbench

After initialization, create an optional project entry:

```sh
moon exec --dev -- hydronium-lab customize
```

This writes `.lab/Workbench.luax` and preserves existing customization.
Use `customize --copy-shell` instead to copy the default document and chrome
markup too. Discovery recognizes the convention; `document` and
`module_roots` in `hydronium.lab.lua` allow an explicit alternative.
Runtime and renderer code remain library imports.

Stories can provide their own DOM controls without replacing the shell.
See [controls and playback](../docs/LAB_CONTROLS.md) for hooks, passive outlets,
opt-in generated fields and virtual time. Customization and these APIs are
unreleased development features.

## DOM and mixed renderer Lab

Use `hydronium-lab init --renderer dom` or `--renderer mixed` for browser stories. Declare `renderer = "dom"` or `"ink"` on collections and stories to share one catalog. Controls update live args; each renderer runs in an isolated preview. DOM uses browser time; Ink retains virtual playback. See [the DOM and mixed Lab guide](../docs/LAB_DOM.md).
