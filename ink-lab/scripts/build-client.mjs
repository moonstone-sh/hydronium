import {readFile, writeFile} from 'node:fs/promises';
import {patchXtermCoordinates} from './xterm-transform.mjs';
const result = await Bun.build({plugins:[{name:'xterm-transform-coordinates',setup(build){build.onLoad({filter:/[\/]@xterm[\/]xterm[\/]lib[\/]xterm\.mjs$/},async ({path})=>({contents:patchXtermCoordinates(await readFile(path,'utf8')),loader:'js'}));}}],entrypoints:['src/hydronium_ink_lab/client/controller.js'],outdir:'src/hydronium_ink_lab/client',naming:'virtual_terminal.js',target:'browser',format:'esm',minify:true});
if (!result.success) throw new AggregateError(result.logs, 'xterm build failed');
await writeFile('src/hydronium_ink_lab/client/ink.css', await readFile('node_modules/@xterm/xterm/css/xterm.css', 'utf8') + '\n' + await readFile('src/hydronium_ink_lab/client/ink-source.css', 'utf8'));
const packages = ['xterm','addon-unicode11'];
await writeFile('src/hydronium_ink_lab/client/XTERM-LICENSES.txt',(await Promise.all(packages.map(async name => `${name}\n${await readFile(`node_modules/@xterm/${name}/LICENSE`, 'utf8')}`))).join('\n'));
