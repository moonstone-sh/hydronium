import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile} from 'node:fs/promises';
import {chromium} from 'playwright';

test('custom canvases omit chrome, isolate shortcuts and retain component DOM on disposal', async t => {
  const source = await readFile(new URL('../../lab/src/hydronium_lab/client/workbench.js', import.meta.url));
  const surface = '<div data-lab-viewport><div data-lab-grid></div><div data-lab-dom-preview style="width:200px;height:100px"></div></div>';
  const server = createServer((req,res) => {
    if(req.url==='/workbench.js'){res.setHeader('content-type','text/javascript');res.end(source);return;}
    res.setHeader('content-type','text/html');
    res.end(`<main id="one"><section data-lab-stage tabindex="0" style="width:400px;height:300px">${surface}<canvas data-lab-rulers></canvas><div data-lab-guide-layer></div><div data-lab-ruler-hit></div></section></main>
      <main id="two"><section data-lab-stage tabindex="0" style="width:400px;height:300px">${surface}</section></main>
      <main id="bare">${surface}</main>
      <script type="module">
      import {installPreviewCanvas} from '/workbench.js';
      window.bindings=['one','two','bare'].map(id=>installPreviewCanvas(document.getElementById(id)));
      window.ready=true;
      </script>`);
  });
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));t.after(()=>server.close());
  const browser=await chromium.launch();t.after(()=>browser.close());
  const page=await browser.newPage();const errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.goto(`http://127.0.0.1:${server.address().port}`);await page.waitForFunction(()=>window.ready);
  assert.equal(await page.locator('#one [data-lab-rulers]').count(),1);
  assert.equal(await page.locator('#two [data-lab-rulers], #two [data-lab-guide-layer], #two [data-lab-ruler-hit]').count(),0);
  await page.locator('#two [data-lab-stage]').focus();await page.keyboard.press('h');
  assert.equal(await page.locator('#two').getAttribute('data-hints-visible'),'false');
  assert.equal(await page.locator('#one').getAttribute('data-hints-visible'),'true');
  await page.evaluate(()=>window.bindings.forEach(binding=>binding.destroy()));
  assert.equal(await page.locator('#one [data-lab-rulers]').count(),1,'component owns ruler DOM');
  await page.keyboard.press('h');
  assert.equal(await page.locator('#two').getAttribute('data-hints-visible'),'false','disposed listeners stay detached');
  assert.deepEqual(errors,[]);
});

test('DOM host mounts a preview without catalog, toolbar, settings or canvas chrome', async t => {
  const assets = new Map(await Promise.all([
    ['/workbench.js','../../lab/src/hydronium_lab/client/workbench.js'],
    ['/preview-settings.js','../../lab/src/hydronium_lab/client/preview-settings.js'],
    ['/dom-lab.js','../../meteorite/src/hydronium_meteorite/client/dom-lab.js'],
  ].map(async ([url,path])=>[url,await readFile(new URL(path,import.meta.url))])));
  const server=createServer((req,res)=>{
    if(assets.has(req.url)){res.setHeader('content-type','text/javascript');res.end(assets.get(req.url));return;}
    res.setHeader('content-type','text/html');
    if(req.url.startsWith('/preview')){res.end(`<div data-lab-base-path="/lab"></div><script>
      const snapshot=()=>({lab:{args:{},playback:{playing:false,frame:0,nowMs:0,intervalMs:16}}});
      window.hydroniumLabPreview={snapshot,request:snapshot,configure:()=>({}),replace:()=>{},reloadStyles:()=>{}};
      parent.postMessage({type:'hydronium-lab-preview-ready'},location.origin);
      </script>`);return;}
    res.end(`<main id="minimal"><iframe data-lab-dom-preview></iframe></main><script type="module">
      import {createDomLab} from '/dom-lab.js';
      const options={root:document.getElementById('minimal'),pollMs:60000,
        fetchCatalog:async()=>({catalog:{stories:[{id:'hello',renderer:'dom',title:'Hello',args:{},controls:{}}]}}),
        loadModules:async()=>({modules:{}}),previewUrl:()=>'/preview'};
      window.lab=await createDomLab(options);window.same=(await createDomLab(options))===window.lab;window.ready=true;
      </script>`);
  });
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));t.after(()=>server.close());
  const browser=await chromium.launch();t.after(()=>browser.close());const page=await browser.newPage();
  const errors=[];page.on('pageerror',error=>errors.push(error.message));
  await page.goto(`http://127.0.0.1:${server.address().port}`);await page.waitForFunction(()=>window.ready);
  assert.equal(await page.evaluate(()=>window.same),true,'mounting a root twice shares its instance');
  assert.equal(await page.locator('#minimal').evaluate(root=>root.childElementCount),1);
  await page.evaluate(()=>window.lab.destroy());
  assert.deepEqual(errors,[]);
});
