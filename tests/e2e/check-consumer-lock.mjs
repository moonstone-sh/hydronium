// The archive hash is the provenance proof; Moonstone may omit registry on replay.
import assert from 'node:assert/strict';
import {readFileSync,readdirSync} from 'node:fs';
import {join} from 'node:path';
const [releaseRoot,lockPath,registry] = process.argv.slice(2);
const expected = new Map();
function walk(dir) {
  for (const entry of readdirSync(dir,{withFileTypes:true})) {
    const path=join(dir,entry.name);
    if(entry.isDirectory()) walk(path);
    else if(entry.name==='package.toml' && path.includes('/dist/registry/')) {
      const descriptor=Bun.TOML.parse(readFileSync(path,'utf8'));
      const name=descriptor.package?.name ?? descriptor.name;
      const version=descriptor.package?.version ?? descriptor.version;
      const artifacts=descriptor.artifacts ?? [];
      expected.set(name,{version,hashes:artifacts.map(a=>a.hash).filter(Boolean)});
    }
  }
}
walk(releaseRoot);
const lock=Bun.TOML.parse(readFileSync(lockPath,'utf8'));
const packages=(lock.realization ?? lock.package ?? []).filter(p=>p.name.startsWith('hydronium/'));
assert.ok(packages.length,'consumer lock must contain Hydronium packages');
for (const p of packages) {
  const candidate=expected.get(p.name);
  assert.ok(candidate,'package was not exported: '+p.name);
  assert.equal(p.version,candidate.version,'wrong candidate version: '+p.name);
  if(p.registry) assert.equal(p.registry,registry,'wrong registry: '+p.name);
  assert.ok(!['path','link','workspace'].includes(p.resolver),'local resolver: '+p.name);
  assert.ok(candidate.hashes.some(hash=>[p.source_hash,p.artifact_hash].includes(hash)),
    'locked source/artifact hash must match this export: '+p.name+' '+JSON.stringify(p));
}
console.log('consumer gate: verified '+packages.length+' exported package versions and archive hashes');
