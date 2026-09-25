# Hydronium Lab CLI

`hydronium-lab` discovers `*.stories.lua` and `*.stories.luax` files, then
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
