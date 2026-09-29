import test from 'node:test';
import assert from 'node:assert/strict';
import {createStoryStore} from '../../lab/src/hydronium_lab/client/workbench.js';
test('story store shares confirmed args/playback, isolates snapshots and unsubscribes', async () => {
  const messages = []; let state = {args:{label:'A'},playback:{nowMs:0,frame:0,playing:true,intervalMs:10}};
  const store = createStoryStore({send:async message=>{
    messages.push(message);
    if(message.op==='args')state.args={...state.args,...message.args};
    if(message.op==='playback')state.playback={...state.playback,...Object.fromEntries(Object.entries(message).filter(([key])=>key!=='op'))};
    if(message.op==='advance')state.playback={...state.playback,nowMs:state.playback.nowMs+state.playback.intervalMs,frame:state.playback.frame+1,playing:false};
    return {lab:structuredClone(state)};
  }});
  store.select({id:'demo',args:{label:'A'},controls:{label:{type:'text'}}});
  let notifications=0; const stop=store.subscribe(()=>notifications++);
  await store.setArgs({label:'B'}); await store.pause(); await store.setInterval(20); await store.advance();
  assert.equal(store.getSnapshot().args.label,'B');
  assert.deepEqual(store.getSnapshot().playback,{nowMs:20,frame:1,playing:false,intervalMs:20});
  const snapshot=store.getSnapshot();snapshot.args.label='leaked';assert.equal(store.getSnapshot().args.label,'B');
  stop();const count=notifications;await store.play();assert.equal(notifications,count);
  assert.deepEqual(messages.map(message=>message.op),['args','playback','playback','advance','playback']);
  store.destroy();
});
