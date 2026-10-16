import { coreLinkArguments } from './swift-core-link.mjs';
import { execFileSync } from 'node:child_process';
import { mkdtemp, mkdir, readdir, readFile, rm, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import path from 'node:path';
import assert from 'node:assert/strict';

const argument = (name, fallback) => process.argv.find(value => value.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const label = argument('label', 'current'); assert.match(label, /^[a-z0-9-]+$/);
const build = path.resolve(argument('core-build', '.build/release')), output = path.resolve('.runtime/history-retention-bench', label);
await mkdir(output, { recursive: true, mode: 0o700 });
const binary = path.join(output, 'check');
execFileSync('/usr/bin/xcrun', ['swiftc', '-O', '-parse-as-library', '-module-cache-path', path.resolve('.build/cache/HistoryRetentionBench'),
  '-I', path.join(build, 'Modules'), '-I', path.resolve('Sources/CSQLite'), '-lsqlite3', ...await coreLinkArguments(build),
  ...(await readdir(path.join(build, 'AutoApproveCore.build'))).filter(name => name.endsWith('.swift.o')).map(name => path.join(build, 'AutoApproveCore.build', name)),
  'Tests/fixtures/history-retention-bench.swift', '-o', binary], { stdio: 'inherit' });
const root = await mkdtemp('/private/tmp/aa-history-retention-'), database = path.join(root, 'history.sqlite');
try {
  execFileSync('/usr/bin/python3', ['-c', `
import sys,json,sqlite3
db=sqlite3.connect(sys.argv[1])
db.executescript('CREATE TABLE thread_history_projection_state(thread_id TEXT PRIMARY KEY,next_rollout_ordinal INTEGER); CREATE TABLE thread_items(thread_id TEXT,item_id TEXT,rollout_ordinal INTEGER,item_type TEXT,updated_at_ordinal INTEGER,item_json TEXT); CREATE INDEX thread_ord ON thread_items(thread_id,rollout_ordinal);')
payload='synthetic ordinary user content '+('cache-data012345 '*4096)
def put(ordinal,item):
    db.execute('INSERT INTO thread_items VALUES(?,?,?,?,?,?)',('fixture',item['id'],ordinal,item['type'],ordinal,json.dumps(item,ensure_ascii=False)))
put(0,{'type':'agentMessage','id':'main','delivery':'async','questions':[{'title':'변경을 적용할까요?','options':['예','아니오']}],'unused':payload})
put(1,{'type':'agentMessage','id':'resolved','delivery':'async','questions':[{'title':'검증 범위','options':[]}],'unused':payload})
put(2,{'type':'userMessage','id':'answer','content':[{'type':'text','text':'> 검증 범위\\n전체'}]})
for index in range(1024): put(index+3,{'type':'userMessage','id':'user-'+str(index),'content':[{'type':'text','text':payload}]})
put(1027,{'type':'agentMessage','id':'late','delivery':'async','questions':[{'title':'다음 단계','options':[]}]})
db.execute('INSERT INTO thread_history_projection_state VALUES(?,?)',('fixture',1028));db.commit();db.close()
`, database], { timeout: 30000 });
  const hash = () => readFile(database).then(data => createHash('sha256').update(data).digest('hex'));
  const originalHash = await hash(), reports = [];
  for (let trial = 0; trial < 3; trial++) reports.push(JSON.parse(execFileSync(binary, [database], { encoding: 'utf8', timeout: 45000 })));
  assert.equal(await hash(), originalHash, 'History measurement must never write the source database');
  const median = values => values.sort((a, b) => a - b)[Math.floor(values.length / 2)];
  const result = { result: 'PASS', label, trials: reports.length, ordinaryMessages: 1024, fixtureSHA256: originalHash,
    memoryScope: 'Own process phys_footprint delta while the reader is alive, including runtime and SQLite costs; not an exact heap allocation count.',
    retainedFootprintBytes: median(reports.map(report => report.retainedFootprintBytes)),
    footprintBytes: median(reports.map(report => report.footprintBytes)), peakResidentBytes: median(reports.map(report => report.peakResidentBytes)),
    firstReadCPUSeconds: median(reports.map(report => report.firstReadCPUSeconds)),
    warmReadsCPUSeconds: median(reports.map(report => report.warmReadsCPUSeconds)), reports };
  await writeFile(path.join(output, 'report.json'), JSON.stringify(result, null, 2));
  const { reports: raw, ...summary } = result; console.log(JSON.stringify(summary, null, 2));
} finally { await rm(root, { recursive: true, force: true }); }
