import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {readFile} from 'node:fs/promises';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
const root = fileURLToPath(new URL('../../', import.meta.url));
const modules = ['core','ink','luax','lab','ink-lab','oklab-utils','dom','router','cli','build','query','virtual','table','create'];
const luaPath = modules.flatMap(name => [`${root}${name}/src/?.lua`, `${root}${name}/src/?/init.lua`]).concat([`${root}.moonstone/env/share/lua/5.1/?.lua`, `${root}.moonstone/env/share/lua/5.1/?/init.lua`, ';;']).join(';');
const {Terminal} = createRequire(import.meta.url)('@xterm/headless');
const output = process.argv[2] ? await readFile(process.argv[2], 'utf8') : (() => {
  const result = spawnSync(`${root}.moonstone/env/bin/lua`, ['tests/xterm_fixture.lua'], {cwd:root, encoding:'utf8', env:{...process.env,LUA_PATH:luaPath}});
  if (result.status !== 0) throw new Error(result.stderr);
  return result.stdout;
})();
const frames = JSON.parse(output);
const terminal = new Terminal({cols:20,rows:6,allowProposedApi:true});
for (const frame of frames) {
  assert.ok(frame.ansi.length, 'full redraw must carry native ANSI');
  terminal.reset();
  await new Promise(resolve => terminal.write(frame.ansi, resolve));
  assert.equal(terminal.buffer.active.getLine(0).translateToString(true).trimEnd(),'ANSI 界');
  assert.equal(terminal.buffer.active.getLine(1).translateToString(true).trimEnd(),'second row');
  assert.ok(terminal.buffer.active.getLine(0).getCell(0).isBold());
  assert.ok(terminal.buffer.active.getLine(1).getCell(0).isItalic());
}
terminal.dispose();
console.log('Native ANSI and explicit resync preserve text, wide glyphs and styles in xterm.');
