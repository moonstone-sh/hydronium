# hydronium/lab-cli

Install Lab into an existing project with:

```sh
moon add --tool hydronium/lab-cli
moon exec -- hydronium-lab init
moon run lab
```

The executable owns discovery and launch orchestration. Rendering belongs to a
Lab renderer package, while HTTP lifecycle belongs to the selected host adapter.
The default setup adds those packages with development roles and keeps the Lab
CLI and Meteorite executable tool-scoped. Rerunning `init` is safe; it does
not try to install the already-running `hydronium/lab-cli` tool again.

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
