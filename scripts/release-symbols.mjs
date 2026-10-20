import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';

const hash=bytes=>createHash('sha256').update(bytes).digest('hex');
const cBytes=bytes=>bytes.subarray(0,bytes.indexOf(0)<0?bytes.length:bytes.indexOf(0));
const cString=bytes=>cBytes(bytes).toString('utf8');
const safeNumber=value=>{const number=Number(value);assert.ok(Number.isSafeInteger(number)&&number>=0);return number;};

// Compare the executable's runtime contents, not the symbol-table layout that
// strip deliberately changes. No symbol names or private paths enter the report.
export function inspectReleaseRuntime(input) {
    const slices=[];
    if(input.readUInt32LE(0)===0xfeedfacf)slices.push(input);
    else {
        const magic=input.readUInt32BE(0),wide=magic===0xcafebabf;
        assert.ok(wide||magic===0xcafebabe,'Expected a 64-bit Mach-O or universal executable');
        const count=input.readUInt32BE(4),stride=wide?32:20;
        assert.ok(count>0&&count<=16&&8+count*stride<=input.length,'Invalid universal header');
        for(let index=0;index<count;index++) {
            const at=8+index*stride;
            const start=wide?safeNumber(input.readBigUInt64BE(at+8)):input.readUInt32BE(at+8);
            const size=wide?safeNumber(input.readBigUInt64BE(at+16)):input.readUInt32BE(at+12);
            assert.ok(size>=32&&start+size<=input.length,'Invalid universal slice');slices.push(input.subarray(start,start+size));
        }
    }
    const result={};
    for(const bytes of slices) {
        assert.equal(bytes.readUInt32LE(0),0xfeedfacf);assert.equal(bytes.readUInt32LE(12),2,'Expected an executable');
        const architecture=bytes.readUInt32LE(4).toString(16)+':'+bytes.readUInt32LE(8).toString(16);
        assert.ok(!result[architecture],'Duplicate architecture');
        const runtime={flags:bytes.readUInt32LE(24),segments:{},sections:{},loaderCommands:[],payloads:{}};
        const sectionNames=[''];let symbols,locals=0,uuid,offset=32;
        const limit=32+bytes.readUInt32LE(20);assert.ok(limit<=bytes.length);
        function payload(name,start,size) {
            assert.ok(start+size<=bytes.length,'Invalid '+name+' payload');runtime.payloads[name]=hash(bytes.subarray(start,start+size));
        }
        for(let index=0;index<bytes.readUInt32LE(16);index++) {
            assert.ok(offset+8<=limit);const command=bytes.readUInt32LE(offset),size=bytes.readUInt32LE(offset+4);
            assert.ok(size>=8&&offset+size<=limit,'Invalid Mach-O command');
            if(command===0x19) {
                assert.ok(size>=72);
                const segmentName=cString(bytes.subarray(offset+8,offset+24));
                if(segmentName!=='__DWARF') {
                    const mapping={address:bytes.readBigUInt64LE(offset+24).toString(),maxProtection:bytes.readUInt32LE(offset+56),
                        initialProtection:bytes.readUInt32LE(offset+60),flags:bytes.readUInt32LE(offset+68)};
                    if(segmentName!=='__LINKEDIT')Object.assign(mapping,{memoryBytes:bytes.readBigUInt64LE(offset+32).toString(),
                        fileOffset:bytes.readBigUInt64LE(offset+40).toString(),fileBytes:bytes.readBigUInt64LE(offset+48).toString()});
                    runtime.segments[segmentName]=mapping;
                }
                for(let section=0;section<bytes.readUInt32LE(offset+64);section++) {
                    const at=offset+72+section*80;assert.ok(at+80<=offset+size);
                    const name=cString(bytes.subarray(at,at+16)),segment=cString(bytes.subarray(at+16,at+32));
                    sectionNames.push(segment+','+name);
                    const flags=bytes.readUInt32LE(at+64),type=flags&255;
                    if(segment==='__DWARF'||(flags&0x02000000)!==0)continue;
                    const length=safeNumber(bytes.readBigUInt64LE(at+40)),start=bytes.readUInt32LE(at+48),zero=[1,12,18].includes(type);
                    assert.ok(zero||start+length<=bytes.length,'Invalid section');
                    runtime.sections[segment+','+name]={address:bytes.readBigUInt64LE(at+32).toString(),length,fileOffset:start,flags,sha256:zero?null:hash(bytes.subarray(start,start+length))};
                }
            } else if(command===2) {
                assert.ok(size>=24);symbols={offset:bytes.readUInt32LE(offset+8),count:bytes.readUInt32LE(offset+12),strings:bytes.readUInt32LE(offset+16),stringBytes:bytes.readUInt32LE(offset+20)};
            } else if(command===0xb) {assert.ok(size>=80);locals=bytes.readUInt32LE(offset+12);}
            else if(command===0x1b) {assert.ok(size>=24);uuid=bytes.subarray(offset+8,offset+24).toString('hex');}
            else if([0x22,0x80000022].includes(command)) {
                assert.ok(size>=48);
                for(const [name,delta]of [['rebase',8],['bind',16],['weakBind',24],['lazyBind',32],['exports',40]])
                    payload(name,bytes.readUInt32LE(offset+delta),bytes.readUInt32LE(offset+delta+4));
            } else if([0x26,0x29,0x2e,0x80000033,0x80000034].includes(command)) {
                assert.ok(size>=16);payload(command.toString(16),bytes.readUInt32LE(offset+8),bytes.readUInt32LE(offset+12));
            } else if([0x5,0xc,0xe,0x27,0x2a,0x80000018,0x8000001f,0x20,0x80000023,0x8000001c,0x80000028,0x32,0x24].includes(command)) {
                runtime.loaderCommands.push({command,sha256:hash(bytes.subarray(offset,offset+size))});
            }
            offset+=size;
        }
        assert.equal(offset,limit);assert.ok(symbols&&uuid,'Missing executable symbols or UUID');
        assert.ok(symbols.offset+symbols.count*16<=bytes.length&&symbols.strings+symbols.stringBytes<=bytes.length,'Invalid symbol table');
        const globals=[];
        for(let index=0;index<symbols.count;index++) {
            const at=symbols.offset+index*16,type=bytes[at+4];if((type&0xe0)!==0||(type&1)===0)continue;
            const start=bytes.readUInt32LE(at);assert.ok(start<symbols.stringBytes);
            const name=cBytes(bytes.subarray(symbols.strings+start,symbols.strings+symbols.stringBytes)).toString('hex');
            const section=bytes[at+5];assert.ok(section<sectionNames.length);
            const value=bytes.readBigUInt64LE(at+8);
            let target=value.toString();
            if((type&0xe)===0xa) {
                const alias=safeNumber(value);assert.ok(alias<symbols.stringBytes);
                target='indirect:'+cBytes(bytes.subarray(symbols.strings+alias,symbols.strings+symbols.stringBytes)).toString('hex');
            }
            globals.push([name,type,sectionNames[section],bytes.readUInt16LE(at+6),target]);
        }
        const ordered=globals.map(value=>JSON.stringify(value)).sort();
        runtime.uuid=uuid;runtime.globalCount=globals.length;runtime.globalSHA256=hash(Buffer.from(JSON.stringify(ordered)));
        result[architecture]={runtime,locals,symbolCount:symbols.count,stringBytes:symbols.stringBytes};
    }
    return result;
}

export function stripReleaseSymbols(app,{archiveDirectory}={}) {
    assert.ok(archiveDirectory,'Keep matching diagnostic binaries outside the application');
    const archive=path.resolve(archiveDirectory),bundle=path.resolve(app);
    assert.ok(archive!==bundle&&!archive.startsWith(bundle+path.sep),'Diagnostic symbols must stay outside the app');
    fs.mkdirSync(archive,{recursive:true,mode:0o700});
    const files=[];
    for(const name of ['AutoApproveApp','autoapprove']) {
        const file=path.join(bundle,'Contents/MacOS',name),stat=fs.lstatSync(file);
        assert.ok(stat.isFile()&&!stat.isSymbolicLink(),'Expected a regular packaged executable');
        const original=fs.readFileSync(file),before=inspectReleaseRuntime(original),originalSHA256=hash(original);
        const backup=path.join(archive,name+'.'+originalSHA256+'.unstripped');
        if(fs.existsSync(backup))assert.equal(hash(fs.readFileSync(backup)),originalSHA256,'Use a fresh diagnostic archive for a different build');
        else {
            try {fs.writeFileSync(backup,original,{mode:0o600,flag:'wx'});}
            catch(error) {if(error.code!=='EEXIST')throw error;assert.equal(hash(fs.readFileSync(backup)),originalSHA256);}
        }
        const staging=fs.mkdtempSync(path.join(path.dirname(file),'.release-symbols-'));
        try {
            const output=path.join(staging,name);
            // Keep globals and runtime loading metadata; re-sign normally later.
            execFileSync('/usr/bin/strip',['-S','-x','-o',output,file],{stdio:'inherit'});
            const bytes=fs.readFileSync(output),after=inspectReleaseRuntime(bytes);
            assert.deepEqual(Object.keys(after).sort(),Object.keys(before).sort(),'Architectures changed');
            for(const architecture of Object.keys(before))assert.deepEqual(after[architecture].runtime,before[architecture].runtime,'Runtime contents changed: '+name+' '+architecture);
            assert.ok(bytes.length<=original.length,'Symbol trimming increased executable size');
            fs.chmodSync(output,stat.mode&0o777);fs.renameSync(output,file);
            files.push({name,beforeBytes:original.length,afterBytes:bytes.length,savedBytes:original.length-bytes.length,
                originalSHA256,trimmedSHA256:hash(bytes),architectures:Object.keys(before).sort(),
                runtimeUnchanged:true,diagnosticArchive:backup,
                symbols:Object.fromEntries(Object.keys(before).map(architecture=>[architecture,{before:before[architecture].symbolCount,after:after[architecture].symbolCount,
                    localsBefore:before[architecture].locals,localsAfter:after[architecture].locals,uuid:before[architecture].runtime.uuid}]))});
        } finally {fs.rmSync(staging,{recursive:true,force:true});}
    }
    const report={files,savedBytes:files.reduce((sum,file)=>sum+file.savedBytes,0),
        scope:'Release packaging only: strip local/debug symbols, preserve runtime sections/addresses, public symbols, UUID and loader metadata, archive original binaries privately, then use normal publisher signing.'};
    fs.writeFileSync(path.join(archive,'report.json'),JSON.stringify(report,null,2)+'\n',{mode:0o600});
    return report;
}
