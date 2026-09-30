import test from 'node:test';
import assert from 'node:assert/strict';
import {viewportGroups} from '../../lab/src/hydronium_lab/client/preview-settings.js';
test('DOM viewports distinguish story, standard and saved user presets and reject malformed stored sizes',()=>{
 const groups=viewportGroups({viewports:[{name:'Card',width:480,height:640}]},[{name:'My screen',width:1111,height:777},{width:-1,height:1}]);
 assert.deepEqual(groups.map(g=>g.label),['Story-specific','Standard','User-defined']);
 assert.equal(groups[0].sizes[0].width,480);assert.equal(groups[2].sizes.length,1);
 assert.equal(viewportGroups({})[0].sizes[0].width,800);
 assert.equal(viewportGroups({},{}).length,2);
});
