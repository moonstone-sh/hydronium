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
