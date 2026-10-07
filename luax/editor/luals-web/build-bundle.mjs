// Packs everything the in-browser LuaLS reads into one file: repeated
// `path \0 length \0 content` (length in bytes), mounted by shim.lua's
// LUALS.mount. Usage: node build-bundle.mjs <luals release dir> <hydronium repo> <out>
import { readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
const [luals, repo, out] = process.argv.slice(2);
const here = fileURLToPath(new URL(".", import.meta.url));
const parts = [];
let count = 0;
const add = (path, buf) => { parts.push(Buffer.from(`${path}\0${buf.length}\0`), buf); count++; };
const walk = (disk, vfs) => {
  for (const name of readdirSync(disk).sort()) {
    const p = join(disk, name);
    if (statSync(p).isDirectory()) walk(p, `${vfs}/${name}`);
    else add(`${vfs}/${name}`, readFileSync(p));
  }
};
// LuaLS: its sources, English strings, and the template it generates the
// standard-library definitions from. (No 3rd-party library defs, other
// locales, or spell lists: the browser does not need them.)
walk(join(luals, "script"), "/luals/script");
walk(join(luals, "locale/en-us"), "/luals/locale/en-us");
walk(join(luals, "meta/template"), "/luals/meta/template");
// Hydronium: the LuaLS plugin (and the LUAX compiler it lowers with), types.
walk(join(repo, "luax/src"), "/hydronium/luax/src");
walk(join(repo, "core/types"), "/hydronium/types/core");
walk(join(repo, "luax/types"), "/hydronium/types/luax");
walk(join(repo, "dom/types"), "/hydronium/types/dom");
add("/luals/boot.lua", readFileSync(join(here, "boot.lua")));
const blob = Buffer.concat(parts);
writeFileSync(out, blob);
console.log(`luals-bundle.bin: ${count} files, ${(blob.length / 1024).toFixed(0)} KiB`);
