import test from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {join} from 'node:path';
import {chromium} from 'playwright';
const root=fileURLToPath(new URL('../../',import.meta.url));
const html=`<!doctype html><main data-hydronium-lab>
<div data-lab-terminal></div><output data-lab-status></output><nav data-lab-stories></nav>
<section data-lab-controls></section>
<section data-lab-controls data-lab-controls-story="custom" hidden><label>Custom label<input data-lab-control="label" aria-label="Custom label"></label></section>
<button data-lab-play>Pause</button><button data-lab-step>Step</button><button data-lab-restart>Restart</button>
<input data-lab-frame-interval type="number" aria-label="Frame interval"><output data-lab-time></output>
</main><script type="module">
import {createInkLab} from '/virtual_terminal.js';import * as workbench from '/workbench.js';
const stories=[{id:'default',title:'Default',args:{label:'A',count:1,enabled:false,choice:2},controls:{label:{type:'text'},count:{type:'number',min:0,max:5},enabled:{type:'boolean'},choice:{type:'select',options:[{label:'Two',value:2},{label:'Three',value:3}]}},sizes:[{name:'default',columns:20,rows:3}],color:'truecolor'}, {id:'custom',title:'Custom',args:{label:'Custom'},controls:{label:{type:'text'}},sizes:[{name:'default',columns:20,rows:3}],color:'truecolor'}];
window.__requests=[];let args={},playback={nowMs:0,frame:0,playing:false,intervalMs:10},seq=0;
window.__lab=await createInkLab({root:document.querySelector('main'),workbench,terminalAdapter:()=>({write:(frame,done)=>done(),font(){},ligatures(){},dispose(){}}),request:async message=>{
window.__requests.push(message);
if(message.op==='catalog')return {stories};
if(message.op==='close')return {};
if(message.op==='open'){args={...stories.find(story=>story.id===message.story).args};playback={...playback,nowMs:0,frame:0,playing:false};}
if(message.op==='args')args={...args,...message.args};
if(message.op==='playback')playback={...playback,...Object.fromEntries(Object.entries(message).filter(([key])=>key!=='op'))};
if(message.op==='advance')playback={...playback,playing:false,nowMs:playback.nowMs+playback.intervalMs,frame:playback.frame+1};
if(message.op==='step'&&playback.playing)playback={...playback,nowMs:message.nowMs,frame:playback.frame+1};
if(message.op==='restart')playback={...playback,nowMs:0,frame:0,playing:false};
return {version:2,kind:'full',seq:++seq,width:20,height:3,terminal:{columns:20,rows:3,inline:false},cursor:null,status:null,styles:{},rows:Array.from({length:3},()=>[[0,Array(20).fill(' ')]]),lab:{args,playback}};
}});
window.__ready=true;
</script>`;
test('default and custom outlets update live args, preserve focus and control virtual playback',async t=>{
const server=createServer(async(req,res)=>{const path=new URL(req.url,'http://localhost').pathname;
if(path==='/'){res.writeHead(200,{'content-type':'text/html'}).end(html);return;}
const file=path==='/virtual_terminal.js'?'ink-lab/src/hydronium_ink_lab/client/virtual_terminal.js':path==='/workbench.js'?'lab/src/hydronium_lab/client/workbench.js':null;
if(!file){res.writeHead(404).end();return;}
res.writeHead(200,{'content-type':'text/javascript'}).end(await readFile(join(root,file)));
});await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));const browser=await chromium.launch();t.after(async()=>{await browser.close();await new Promise(resolve=>server.close(resolve));});const page=await browser.newPage(),errors=[];page.on('pageerror',error=>errors.push(String(error)));
await page.goto('http://127.0.0.1:'+server.address().port);await page.waitForFunction(()=>window.__ready);
await page.getByRole('textbox',{name:'label',exact:true}).fill('Edited');await page.waitForFunction(()=>window.__lab.state.getSnapshot().args.label==='Edited');
assert.equal(await page.evaluate(()=>document.activeElement.dataset.labControl),'label');
await page.getByRole('spinbutton',{name:'count',exact:true}).fill('4');await page.getByRole('checkbox',{name:'enabled'}).check();await page.getByRole('combobox',{name:'choice'}).selectOption({label:'Three'});
await page.waitForFunction(()=>window.__lab.state.getSnapshot().args.choice===3);assert.deepEqual(await page.evaluate(()=>window.__lab.state.getSnapshot().args),{label:'Edited',count:4,enabled:true,choice:3});
assert.equal(await page.evaluate(()=>window.__requests.filter(message=>message.op==='open').length),1);
await page.getByRole('spinbutton',{name:'Frame interval'}).fill('25');await page.getByRole('spinbutton',{name:'Frame interval'}).blur();await page.waitForFunction(()=>window.__lab.state.getSnapshot().playback.intervalMs===25);
await page.getByRole('button',{name:'Step',exact:true}).click();await page.waitForFunction(()=>window.__lab.state.getSnapshot().playback.nowMs===25);assert.equal(await page.locator('[data-lab-time]').textContent(),'25.00 ms · frame 1');
await page.getByRole('button',{name:'Play playback'}).click();await page.waitForFunction(()=>window.__lab.state.getSnapshot().playback.nowMs>25);await page.getByRole('button',{name:'Pause playback'}).click();await page.waitForFunction(()=>!window.__lab.state.getSnapshot().playback.playing);const frozen=await page.evaluate(()=>window.__lab.state.getSnapshot().playback.nowMs);await page.waitForTimeout(200);assert.equal(await page.evaluate(()=>window.__lab.state.getSnapshot().playback.nowMs),frozen);
await page.getByRole('button',{name:'Restart',exact:true}).click();await page.waitForFunction(()=>window.__lab.state.getSnapshot().playback.nowMs===0);
await page.getByRole('button',{name:'Custom',exact:true}).click();await page.getByRole('textbox',{name:'Custom label'}).fill('Custom edit');await page.waitForFunction(()=>window.__lab.state.getSnapshot().args.label==='Custom edit');assert.equal(await page.locator('[data-lab-controls]:not([data-lab-controls-story])').isVisible(),false);
await page.evaluate(()=>window.__lab.close());assert.deepEqual(errors,[]);
});
