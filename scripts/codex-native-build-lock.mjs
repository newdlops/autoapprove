// The upstream release manifest is 0.166.0 while local lock entries are 0.0.0.
// Normalize ONLY pinned local package versions; never update a registry/Git pin.
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
export function normalizeNativeBuildLock(text,manifest){
 const hash=value=>createHash('sha256').update(value).digest('hex');
 const rule=manifest.buildLock;
 assert.equal(rule?.kind,'local-workspace-version-only');
 assert.equal(rule.version,'0.166.0');
 assert.equal(hash(text),rule.before);
 let count=0;
 const result=text.split('[[package]]').map(block=>{
  if(!/^source = /m.test(block)&&/^version = "0.0.0"$/m.test(block)){
   count++;return block.replace(/^version = "0.0.0"$/m,'version = "'+rule.version+'"');
  }
  return block;
 }).join('[[package]]');
 assert.equal(count,rule.entries);assert.equal(hash(result),rule.after);
 return result;
}
