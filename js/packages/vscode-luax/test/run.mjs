// Runs the extension inside a real VS Code (downloaded by @vscode/test-electron
// into .vscode-test/) against a throwaway copy of test/fixture, with
// lua-language-server from LUALS_PATH or PATH.
import { runTests } from "@vscode/test-electron";
import { cpSync, mkdtempSync, mkdirSync, writeFileSync, existsSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve, delimiter } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const extension = resolve(here, "../../../../luax");

const server = process.env.LUALS_PATH || (process.env.PATH || "").split(delimiter)
  .map((dir) => join(dir, "lua-language-server")).find((p) => existsSync(p));
if (!server) {
  console.error("lua-language-server not found: set LUALS_PATH");
  process.exit(1);
}

const workspace = mkdtempSync(join(tmpdir(), "hydronium-luax-vscode-"));
cpSync(join(here, "fixture"), workspace, { recursive: true });
mkdirSync(join(workspace, ".vscode"), { recursive: true });
writeFileSync(join(workspace, ".vscode/settings.json"), JSON.stringify({ "hydroniumLuax.server.path": server }, null, 2));
const results = join(workspace, "results.json");
// macOS caps socket paths at 103 characters; VS Code puts one in its user-data dir.
const userData = mkdtempSync(join(tmpdir(), "hlx-ud-"));

let code = 0;
try {
  await runTests({
    ...(process.env.VSCODE_EXECUTABLE ? { vscodeExecutablePath: process.env.VSCODE_EXECUTABLE } : { version: process.env.VSCODE_VERSION || "stable" }),
    extensionDevelopmentPath: extension,
    extensionTestsPath: join(here, "suite.cjs"),
    launchArgs: [workspace, "--user-data-dir", userData, "--disable-extensions", "--disable-workspace-trust", "--skip-welcome", "--skip-release-notes"],
    extensionTestsEnv: { HYDRONIUM_LUAX_RESULTS: results },
  });
} catch (error) {
  code = 1;
  console.error(error);
}
if (existsSync(results)) {
  const checks = JSON.parse(readFileSync(results, "utf8"));
  for (const c of checks) console.log(`${c.ok ? "PASS" : "FAIL"} ${c.name}${c.detail ? ` -- ${c.detail}` : ""}`);
  if (checks.some((c) => !c.ok)) code = 1;
} else {
  code = 1;
}
rmSync(workspace, { recursive: true, force: true });
rmSync(userData, { recursive: true, force: true });
process.exit(code);
