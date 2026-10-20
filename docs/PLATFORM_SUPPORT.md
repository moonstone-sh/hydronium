# Native platform support

Hydronium's shared rendering and reactivity code does not require a POSIX host.
OS-specific terminal and developer-tool effects live behind Moonstone flavors.
The `Native Windows framework and Ink` CI job is the native Windows gate.

| Surface | Windows contract |
| --- | --- |
| Signals, reconciliation, routing, Query, Virtual, Table | Shared Lua tests run on native Windows. |
| DOM/browser adapter | Uses the browser's APIs; client adapter tests also run on Windows Node.js. |
| Ink layout | Bundled x86-64 Yoga DLL, loaded through LuaJIT FFI. |
| Interactive Ink | Windows 10/11 native console or Windows Terminal with virtual terminal output. |
| Scaffolding | Flag-driven file generation and native console detection; no Unix `mkdir`, `ls`, or `test`. |
| Development | Clingy Job Object ownership; native process liveness and source enumeration. |
| Source-mode Ink HMR | Native source enumeration; shared component-family HMR preserves state. |

## Flavor boundaries

`hydronium_ink.clock@windows.lua`, `tty_ffi@windows.lua`, and
`source_files@windows.lua` replace their POSIX counterparts. Projected consumers
use ordinary `require` calls. A source-tree entry point that puts variant files
on `package.path` must install `require("moonstone.variants").install()` once.
The native test runner does this on Windows.

The CLI and scaffolder resolve their own small platform boundaries through
`moonstone.variants.resolve`; they do not introduce a global loader hook merely
to select one backend. Browser-shipped code retains static imports and the
Quaver checks governing its reflective boundaries.

The Windows clock uses QueryPerformanceCounter for intervals, anchored to Unix
milliseconds for existing event timestamps. Console input uses native key
records, including repeat counts, UTF-16 surrogate pairs, navigation modifiers,
and Ctrl+C as input. Raw mode disables line buffering, echo and quick edit;
normal exit, errors and partial initialization restore the saved console modes
and output codepage. Both stdin and stdout must be consoles for interactive
rendering; redirected sessions remain noninteractive.

## Installation and development tools

Ink's source artifact contains the prebuilt libraries as target-scoped assets.
The copy-only materializer needs no `sh`, `uname`, or `cp`. Loading one library
from the selected package root also avoids putting foreign-target libraries on
the host loader's search path. Local path dependencies use `native/dist`.

Windows development uses Clingy's kill-on-close Job Object supervisor, tied to
the Hydronium CLI's real process identity. Stopping the supervisor closes its
job and reaps descendants. The child runs through `moon exec --dev` so command
launchers, tool scopes and arguments use Moonstone's platform contract.
PowerShell starts the supervisor once; native APIs handle liveness checks and
source polling without launching a shell on each UI tick.

Shell-backed build tools retain their explicit input restrictions: arguments
that cmd.exe would reinterpret are rejected by the existing serializers.
This is distinct from native console Unicode input and UTF-16 source discovery.
Windows ARM64 has no published Ink Yoga payload and is not certified here.
MSYS/mintty pipes are not a substitute for a native Windows console.

Portable forwarding in named `moon run` scripts requires Moonstone's portable
script contract (Moonstone PR #11). The native job pins its merged commit until
a tagged Moonstone release includes it. This change does not imply that older
Moonstone releases automatically acquired that behavior.

## What CI proves

The Windows job builds its pinned Moonstone CLI, exports the candidate Ink
artifact, publishes it to a disposable file registry and installs a fresh
consumer. It then runs shared framework and Ink HMR tests, loads the actual
Yoga DLL, scaffolds a project into a path containing spaces, and checks source
discovery. A real allocated console receives injected Unicode, navigation and
Ctrl+C records; the test checks raw flags and restoration. A separate process
contract checks argument boundaries and descendant cleanup after stopping the
development supervisor. Browser-adapter tests run under Windows Node.js.

The native job is a release gate, not evidence of support until it passes.
The public LuaJIT 2.1.0 and 2.1.1783773675 descriptors currently contain no
Windows artifacts. A Windows runtime publication is required before this gate
can install Ink and certify the Windows consumer lifecycle. Cross compilation
and mocked console tests alone do not establish native support.
