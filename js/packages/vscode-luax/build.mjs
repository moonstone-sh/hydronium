// Builds the VS Code / VSCodium extension into luax/ (where its manifest,
// grammar and LuaLS plugin already live):
//
//   luax/dist/extension.cjs      the bundled extension (vscode-languageclient included)
//   luax/dist/types/{core,luax,dom}   type libraries for folders without a .luarc.json
//
// `node build.mjs --package` also writes luax/hydronium-luax-<version>.vsix.
import { build } from "esbuild";
import { cpSync, rmSync, mkdirSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, "../../..");
const luax = join(repo, "luax");
const dist = join(luax, "dist");

rmSync(join(dist, "extension.cjs"), { force: true });
rmSync(join(dist, "types"), { recursive: true, force: true });
mkdirSync(dist, { recursive: true });

await build({
  entryPoints: [join(here, "src/extension.mjs")],
  outfile: join(dist, "extension.cjs"),
  bundle: true,
  platform: "node",
  format: "cjs",
  target: "node18",
  external: ["vscode"],
  minify: true,
  sourcemap: false,
  legalComments: "none",
});

cpSync(join(repo, "core/types"), join(dist, "types/core"), { recursive: true });
cpSync(join(luax, "types"), join(dist, "types/luax"), { recursive: true });
cpSync(join(repo, "dom/types"), join(dist, "types/dom"), { recursive: true });
console.log("built luax/dist/extension.cjs and luax/dist/types");

if (process.argv.includes("--package")) {
  const { version } = JSON.parse(readFileSync(join(luax, "package.json"), "utf8"));
  const out = join(luax, `hydronium-luax-${version}.vsix`);
  execFileSync(join(here, "node_modules/.bin/vsce"), ["package", "--no-dependencies", "--readme-path", "VSCODE_README.md", "--out", out], { cwd: luax, stdio: "inherit" });
}
