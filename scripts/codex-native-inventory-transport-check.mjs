// Compile the actual patched transport module with minimal event-channel types.
// This is NOT the full TUI or the App-state snapshot test.
import assert from 'node:assert/strict';
import {readFile,mkdir,mkdtemp,writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {spawn} from 'node:child_process';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
const option=name=>process.argv.find(v=>v.startsWith('--'+name+'='))?.slice(name.length+3);
assert.ok(option('source'),'Provide --source=/prepared/codex-rs');
const source=path.resolve(option('source')),module=source+'/tui/src/native_inventory.rs';
const manifest=JSON.parse(await readFile(fileURLToPath(new URL('../patches/codex/0.166.0-native-inventory.manifest.json',import.meta.url)),'utf8'));
const hash=bytes=>createHash('sha256').update(bytes).digest('hex');
assert.equal(hash(await readFile(module)),manifest.files.find(v=>v.path==='tui/src/native_inventory.rs').after);
const lock=await readFile(source+'/Cargo.lock','utf8');assert.equal(hash(Buffer.from(lock)),manifest.pins['Cargo.lock']);
function version(name){
 const block=lock.split('[[package]]').find(v=>v.includes('\nname = "'+name+'"\n'));
 assert.ok(block,'Missing native direct dependency: '+name);return block.match(/version = "([^"]+)"/)[1];
}
const parent=path.resolve(option('output')||'.runtime/native-inventory-transport');await mkdir(parent,{recursive:true,mode:0o700});
const root=await mkdtemp(parent+'/check-');await mkdir(root+'/src');
const deps=['anyhow','libc','serde_json','tempfile'].map(v=>`${v} = "=${version(v)}"`);
deps.push(`serde = {version="=${version('serde')}",features=["derive"]}`);
deps.push(`tokio = {version="=${version('tokio')}",features=["rt-multi-thread","macros","net","io-util","sync","time"]}`);
await writeFile(root+'/Cargo.toml',`[package]\nname="native-inventory-transport-source-check"\nversion="0.0.0"\nedition="2024"\n[dependencies]\n${deps.join('\n')}\n[workspace]\n`);
await writeFile(root+'/src/lib.rs',`#![allow(dead_code)]
mod app_event { #[derive(Debug)] pub enum AppEvent { Other, AutoapproveInventoryRead {nonce:String,reply:tokio::sync::oneshot::Sender<serde_json::Value>} } }
mod app_event_sender { #[derive(Clone)] pub struct AppEventSender {pub app_event_tx:tokio::sync::mpsc::UnboundedSender<crate::app_event::AppEvent>} impl AppEventSender {pub fn new(app_event_tx:tokio::sync::mpsc::UnboundedSender<crate::app_event::AppEvent>)->Self{Self{app_event_tx}}} }
#[path=${JSON.stringify(module)}] mod native_inventory;
`);
const child=spawn(option('cargo')||'cargo',['+stable','test','--jobs','2'],{cwd:root,stdio:'inherit',
 env:{...process.env,CARGO_HOME:path.join(parent,'cargo-home')}});
const code=await new Promise((resolve,reject)=>{child.once('error',reject);child.once('close',resolve);});
assert.equal(code,0,'Native transport source tests failed');
console.log(JSON.stringify({verified:true,scope:'actual transport module with minimal event-channel types',
 tests:3,fullTUI:false,appSnapshotVerified:false,migrationVerified:false,root}));
