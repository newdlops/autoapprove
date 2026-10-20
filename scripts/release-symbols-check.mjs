import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {inspectReleaseRuntime,stripReleaseSymbols} from './release-symbols.mjs';

const input=path.resolve(process.argv[2]??'.build/release');
const root=fs.mkdtempSync('/private/tmp/aa-release-symbols-');
const hash=bytes=>createHash('sha256').update(bytes).digest('hex');
const originals=Object.fromEntries(['AutoApproveApp','autoapprove'].map(name=>[name,fs.readFileSync(path.join(input,name))]));
const sources={};
for(const [name,bytes]of Object.entries(originals)) {
    const architectures=Object.keys(inspectReleaseRuntime(bytes));
    if(architectures.length===1)sources[name]=bytes;
    else {
        const architecture=architectures.some(value=>value.startsWith('100000c:'))?'arm64':'x86_64';
        const output=path.join(root,name+'-thin');
        execFileSync('/usr/bin/lipo',[path.join(input,name),'-thin',architecture,'-output',output],{stdio:'inherit'});
        sources[name]=fs.readFileSync(output);
    }
}
function create(name,values) {
    const app=path.join(root,name+'.app'),directory=path.join(app,'Contents/MacOS');fs.mkdirSync(directory,{recursive:true});
    for(const [file,bytes]of Object.entries(values))fs.writeFileSync(path.join(directory,file),bytes,{mode:0o700});return app;
}
function globals(file) {
    return execFileSync('/usr/bin/nm',['-g','-P',file],{encoding:'utf8',maxBuffer:8*1024*1024}).split('\n').filter(line=>line.trim()&&!line.endsWith(':')).sort().join('\n');
}
try {
    const app=create('thin',sources),before={};
    for(const name of Object.keys(sources))before[name]=globals(path.join(app,'Contents/MacOS',name));
    const report=stripReleaseSymbols(app,{archiveDirectory:path.join(root,'thin-symbols')});
    assert.ok(report.savedBytes>1_048_576,'Real release copies should lose their local/debug tables');
    for(const file of report.files) {
        const current=path.join(app,'Contents/MacOS',file.name);
        assert.equal(globals(current),before[file.name],'External nm names, types and values changed');
        assert.ok(fs.readFileSync(file.diagnosticArchive).equals(sources[file.name]),'Diagnostic original must be exact');
        assert.ok(fs.readFileSync(path.join(input,file.name)).equals(originals[file.name]),'Build/installed input changed');
        assert.deepEqual(fs.readdirSync(path.dirname(current)).sort(),Object.keys(sources).sort(),'Temporary files escaped into the bundle');
    }
    const corrupt=Buffer.from(sources.AutoApproveApp);let offset=32,changed=false;
    for(let i=0;i<corrupt.readUInt32LE(16)&&!changed;i++) {
        const command=corrupt.readUInt32LE(offset),size=corrupt.readUInt32LE(offset+4);
        if(command===0x19)for(let j=0;j<corrupt.readUInt32LE(offset+64);j++) {
            const at=offset+72+j*80,name=corrupt.subarray(at,at+16).toString().replace(/\0.*$/s,'');
            if(name==='__text'){corrupt[corrupt.readUInt32LE(at+48)]^=1;changed=true;break;}
        }
        offset+=size;
    }
    assert.ok(changed);assert.notDeepEqual(inspectReleaseRuntime(corrupt),inspectReleaseRuntime(sources.AutoApproveApp),'Runtime byte tampering must change the verification');
    const protection=Buffer.from(sources.AutoApproveApp);offset=32;let changedProtection=false;
    for(let i=0;i<protection.readUInt32LE(16);i++) {
        const command=protection.readUInt32LE(offset),size=protection.readUInt32LE(offset+4);
        if(command===0x19&&protection.subarray(offset+8,offset+24).toString().startsWith('__TEXT\0')) {
            protection.writeUInt32LE(protection.readUInt32LE(offset+60)^2,offset+60);changedProtection=true;break;
        }
        offset+=size;
    }
    assert.ok(changedProtection);assert.notDeepEqual(inspectReleaseRuntime(protection),inspectReleaseRuntime(sources.AutoApproveApp),'Memory protection changes must be detected');
    assert.throws(()=>stripReleaseSymbols(app,{archiveDirectory:path.join(app,'symbols')}),/outside the app/);
    const bad=create('invalid',{AutoApproveApp:Buffer.from('invalid executable'),autoapprove:sources.autoapprove});
    assert.throws(()=>stripReleaseSymbols(bad,{archiveDirectory:path.join(root,'bad-symbols')}));
    const symlink=path.join(root,'symlink.app'),directory=path.join(symlink,'Contents/MacOS');fs.mkdirSync(directory,{recursive:true});
    fs.symlinkSync(path.join(input,'AutoApproveApp'),path.join(directory,'AutoApproveApp'));
    assert.throws(()=>stripReleaseSymbols(symlink,{archiveDirectory:path.join(root,'link-symbols')}),/regular packaged executable/);
    // Both universal header widths use a real thin slice plus a nonexecuted
    // cross-architecture fixture. This is metadata, not runtime, coverage.
    const source=path.join(root,'fixture.c'),cross=path.join(root,'fixture-cross'),thin=path.join(root,'fixture-thin');
    fs.writeFileSync(source,'__attribute__((noinline)) static int local_function(int value) { return value + 3; }\nint exported_value = 7;\nint main(int argc, char **argv) { return local_function(argc) + exported_value; }\n');
    const host=inspectReleaseRuntime(sources.AutoApproveApp);
    const keys=Object.keys(host);assert.equal(keys.length,1);
    const crossArchitecture=keys[0].startsWith('100000c:')?'x86_64':'arm64';
    execFileSync('/usr/bin/xcrun',['clang','-arch',crossArchitecture,'-g','-O2',source,'-o',cross],{stdio:'inherit'});
    fs.writeFileSync(thin,sources.AutoApproveApp);
    for(const wide of [false,true]) {
        const kind=wide?'fat64':'fat32',fat=path.join(root,kind);
        execFileSync('/usr/bin/lipo',['-create',...(wide?['-fat64']:[]),thin,cross,'-output',fat],{stdio:'inherit'});
        const universalBytes=fs.readFileSync(fat),universal=create(kind,{AutoApproveApp:universalBytes,autoapprove:universalBytes});
        const expected=inspectReleaseRuntime(universalBytes);assert.equal(Object.keys(expected).length,2);
        const fatGlobals=globals(path.join(universal,'Contents/MacOS/AutoApproveApp'));
        const fatReport=stripReleaseSymbols(universal,{archiveDirectory:path.join(root,kind+'-symbols')});
        for(const file of fatReport.files) {
            const executable=path.join(universal,'Contents/MacOS',file.name),after=inspectReleaseRuntime(fs.readFileSync(executable));
            for(const architecture of Object.keys(expected))assert.deepEqual(after[architecture].runtime,expected[architecture].runtime);
            assert.equal(globals(executable),fatGlobals);
            assert.ok(fs.readFileSync(file.diagnosticArchive).equals(universalBytes));
        }
    }
    console.log(JSON.stringify({passed:true,realThinCopies:2,universalCopies:4,universalHeaderWidths:[32,64],independentNMVerified:true,sourceBinariesUnchanged:true,
        diagnosticOriginalsExact:true,detectsRuntimeTampering:true,detectsMemoryProtectionTampering:true,rejectsInvalidSymlinkAndBundledArchive:true,
        thinSavedBytes:report.savedBytes,universalArchitectures:2,crossArchitectureExecuted:false,originalTerminalInputs:0}));
} finally {fs.rmSync(root,{recursive:true,force:true});}
