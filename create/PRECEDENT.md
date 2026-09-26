# Precedent: runtime dependency isolation in monorepo packages

## Incident summary

On 2026-09-26, running `hydronium-create@0.5.0` via `moon exec --global -- hydronium-create` failed immediately upon invocation:

```text
! ...create-0.5.0/files/libexec/hydronium-create/src/main.lua:144: module 'hydronium' not found:
    no field package.preload['hydronium']
    no file '.../files/libexec/hydronium-create/src/hydronium.lua'
    ...
```

The tool crashed before rendering the first frame of the terminal user interface.

## Root cause analysis

The failure resulted from an incorrect dependency classification in `create/moonstone.toml`, paired with Ballad's correct dependency pruning during registry packaging.

1. **Dynamic require on interactive execution branch.**
   When `hydronium-create` runs without template arguments on a TTY, `create/src/main.lua` launches the interactive Ink wizard:
   ```lua
   if ctx.args.wizard or (is_tty and not has_explicit_choice) then
     local hydronium = require("hydronium")
     local ink_render = require("hydronium_ink.render")
     local wizard_app = require("create.ui.wizard_app")
     ...
   ```
   Furthermore, `create/src/create/ui/logo.lua` requires `hydronium_oklab_utils`.

2. **Misclassification as development dependencies.**
   In `create/moonstone.toml`, `hydronium/core`, `hydronium/ink`, and `hydronium/oklab-utils` were classified under `role = "dev"`. The inline comment assumed these packages were only loaded by `hydronium-lab` when evaluating Component Lab stories, and claimed to mirror `hydronium/cli` (which actually declared them under `role = "runtime"`).

3. **Pruning during packaging.**
   Ballad's `moonstone.registry` export plugin filters out non-runtime dependencies. When generating `dist/registry/create/package.toml`, Ballad included only `alter`, `alter-jsonc`, and `clingy`. The published package omitted `hydronium/core`, `hydronium/ink`, and `hydronium/oklab-utils`.

4. **Consumer environment isolation.**
   In consumer environments, Moonstone materialized only the declared runtime dependencies into `.moonstone/env/`. The modules required by line 144 did not exist on `package.path`, triggering `module 'hydronium' not found`.

## Masking mechanisms

Three distinct factors prevented unit tests and local runs from catching the bug prior to publication:

1. **Non-interactive test execution.**
   Unit tests (`tests/create_spec.lua`) ran with redirected stdin (`< /dev/null`). In non-interactive mode, `detect_tty()` returned `false`, bypassing the wizard launcher branch entirely.

2. **Monorepo environment bleed.**
   During local development, developers ran tests and ad-hoc commands within the monorepo. Sibling packages (`../core`, `../ink`, `../oklab-utils`) were either symlinked in the root `.moonstone/env` or exposed via development search paths.

3. **Incomplete static require validation.**
   Unit test 71 inspected `src/` to verify that all required `create.*` modules were registered in Ballad's `partiture.lua` include list. It did not validate foreign package requirements against the runtime dependency manifest.

## Remediation

1. **Manifest updates in `create/moonstone.toml`:**
   - Promoted `hydronium/core` (`path:../core`), `hydronium/ink` (`path:../ink`), and `hydronium/oklab-utils` (`path:../oklab-utils`) to `role = "runtime"`.
   - Retained `hydronium/lab` (`path:../lab`) as `role = "dev"`.
   - Bumped package version from `0.5.0` to `0.5.1`.

2. **Artifact verification:**
   Exported the package with `moon run package` (under `ulimit -n 4096`). Verified that `dist/registry/create/package.toml` includes:
   ```toml
   [[dependencies]]
   name = "hydronium/core"
   constraint = "^0.2.1"
   resolver = "moonstone"
   role = "runtime"

   [[dependencies]]
   name = "hydronium/ink"
   constraint = "^0.5.0"
   resolver = "moonstone"
   role = "runtime"

   [[dependencies]]
   name = "hydronium/oklab-utils"
   constraint = "^0.3.0"
   resolver = "moonstone"
   role = "runtime"
   ```

3. **Lockfile synchronization:**
   Ran `moon sync --update` in `create/` to record the updated dependency roles in `moonstone.lock`.

## Mandatory invariants for monorepo packages

All packages in the monorepo must adhere to the following rules:

1. **Direct runtime closure.**
   If an exported binary or library requires a module during any reachable code path (including optional or TTY-specific UI flows), that module must be declared with `role = "runtime"` in `moonstone.toml`. The `dev` role is reserved strictly for test runners, development-only scripts, and workbench tools.

2. **Monorepo environment distrust.**
   Never certify a package release solely on the basis of in-tree execution. Sibling package visibility in local development obscures missing runtime dependencies.

3. **Dual execution branch verification.**
   Tools with interactive TTY branches and non-interactive scripting modes must exercise both execution paths in an isolated environment before release publication.
