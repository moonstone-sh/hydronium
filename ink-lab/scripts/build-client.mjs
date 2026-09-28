import {readFile, writeFile} from 'node:fs/promises';
const result = await Bun.build({entrypoints:['src/hydronium_ink_lab/client/controller.js'],outdir:'src/hydronium_ink_lab/client',naming:'virtual_terminal.js',target:'browser',format:'esm',minify:true});
if (!result.success) throw new AggregateError(result.logs, 'xterm build failed');
await writeFile('src/hydronium_ink_lab/client/ink.css', await readFile('node_modules/@xterm/xterm/css/xterm.css', 'utf8') + '\n' + await readFile('src/hydronium_ink_lab/client/ink-source.css', 'utf8'));
const packages = ['xterm','addon-unicode11'];
await writeFile('src/hydronium_ink_lab/client/XTERM-LICENSES.txt',(await Promise.all(packages.map(async name => `${name}\n${await readFile(`node_modules/@xterm/${name}/LICENSE`, 'utf8')}`))).join('\n'));
