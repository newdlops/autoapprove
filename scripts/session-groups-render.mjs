import {execFileSync} from 'node:child_process';
import {mkdir,readFile,writeFile,access} from 'node:fs/promises';
import {existsSync} from 'node:fs';
import path from 'node:path';
import {coreLinkArguments} from './swift-core-link.mjs';
const option=n=>process.argv.find(v=>v.startsWith('--'+n+'='))?.slice(n.length+3);
const build=path.resolve(option('build')||'.build/debug');
const out=path.resolve(option('output')||'/private/tmp/autoapprove-session-groups-render');
await mkdir(out,{recursive:true});
const binary=out+'/SessionGroupsRender';
const core=path.join(build,'AutoApproveCore.build');
const map=JSON.parse(await readFile(path.join(core,'output-file-map.json'),'utf8'));
const objects=Object.entries(map).filter(([source,value])=>source.endsWith('.swift') && typeof value.object==='string').map(([,value])=>path.join(core,path.basename(value.object)));
if (!objects.length || new Set(objects).size!==objects.length) throw new Error('Invalid core object map');
await Promise.all(objects.map(object=>access(object)));
const verifyRefresh=process.argv.includes('--verify-refresh');
const verifyDrag=process.argv.includes('--verify-drag');
const verifyOpen=process.argv.includes('--verify-open');
const verifyGraphRefresh=process.argv.includes('--verify-graph-refresh');
const graphScenes=process.argv.includes('--graph');
let source='Sources/AutoApproveApp/SessionGroupsWindow.swift';
if(verifyRefresh) {
  const original=await readFile(source,'utf8'),marker='    var body: some View {';
  if(!original.includes(marker))throw Error('Missing group body instrumentation point');
  source=out+'/SessionGroupsWindow.swift';
  await writeFile(source,original.replace(marker,marker+'\n        let _ = GroupRefreshProbe.observe(groups)'));
}
// The graph root body, the graph area body and the drag preview's display callback
// are counted by inserting probe calls into a copy of the sources.
let graph=option('graph-source')||'Sources/AutoApproveApp/SessionGroupConversationGraph.swift';
let model='Sources/AutoApproveApp/SessionGroupConversationGraphModel.swift';
const hasModel=existsSync(model);
if(verifyOpen||verifyDrag||verifyGraphRefresh) {
  let text=await readFile(graph,'utf8');
  const body='    var body: some View {';
  const rootStart=text.indexOf('struct SessionGroupConversationGraph');
  const rootBody=text.indexOf(body,rootStart);
  if(rootStart<0||rootBody<0)throw Error('Missing graph root body');
  const rootProbe=verifyGraphRefresh?'        let _ = GraphProbe.root(model.content?.page.messages.count)':'        let _ = GraphProbe.root()';
  text=text.slice(0,rootBody+body.length)+'\n'+rootProbe+text.slice(rootBody+body.length);
  const canvasStart=[text.indexOf('struct ConversationGraphCanvas'),text.indexOf('struct GroupConversationNodes')].find(i=>i>=0);
  const canvasBody=canvasStart===undefined?-1:text.indexOf(body,canvasStart);
  if(canvasBody<0)throw Error('Missing graph area body');
  text=text.slice(0,canvasBody+body.length)+'\n        let _ = GraphProbe.canvas()'+text.slice(canvasBody+body.length);
  const frame='    @objc private func displayFrame() {';
  if(!text.includes(frame))throw Error('Missing drag preview frame callback');
  text=text.replace(frame,frame+'\n        GraphProbe.frame()');
  // Node centers in window coordinates, so the harness can press a node without accessibility.
  const oldNode='        .frame(width: 128, height: 61, alignment: .top)\n    }\n';
  const place='.background(GeometryReader { g in let _ = GraphProbe.place(PROBE_NAME, CGPoint(x: g.frame(in: .global).midX, y: g.frame(in: .global).minY + PROBE_TOP)); Color.clear })';
  // The circle centre is 13pt above the node view's centre at 100%, and the node is 128pt wide,
  // so the width gives the zoom. The frame (circle and name band) is kept for overlap checks.
  const scaledPlace='.background(GeometryReader { g in let f = g.frame(in: .global); let _ = GraphProbe.place(node.name, CGPoint(x: f.midX, y: f.midY - GraphNodeView.centerOffset * f.width / GraphNodeView.width), frame: f); Color.clear })';
  if(text.includes('/* graph-probe: node */'))text=text.replace('/* graph-probe: node */',scaledPlace);
  else if(text.includes(oldNode))text=text.replace(oldNode,'        .frame(width: 128, height: 61, alignment: .top)\n        '+place.replace('PROBE_NAME','member.title').replace('PROBE_TOP','19')+'\n    }\n');
  else throw Error('Missing node instrumentation point');
  // The zoom and pan of the graph area, and the lifted node's circle centre in window coordinates.
  text=text.replace('/* graph-probe: viewport */','let _ = GraphProbe.viewport(view)');
  // The selected member's name, and each matrix header's and cell's frame, so the harness can press a cell.
  text=text.replace('/* graph-probe: selection */','let _ = GraphProbe.selected(selection.flatMap { id in nodes.first { $0.id == id }?.name })');
  text=text.replace('/* graph-probe: cell */','.background(GeometryReader { g in let _ = GraphProbe.cell(probeName, g.frame(in: .global)); Color.clear })');
  // The zoom buttons' frame, so the harness can press and scroll over them.
  text=text.replace('/* graph-probe: zoom */','.background(GeometryReader { g in let _ = GraphProbe.zoomControls(g.frame(in: .global)); Color.clear })');
  text=text.replace('/* graph-probe: preview */','GraphProbe.preview(surface.convert(CGPoint(x: node.position.x, y: node.position.y + GraphNodeView.centerOffset * CGFloat(transform.scale)), to: nil))');
  const begin=text.match(/\n    func begin\([^{]*\{\n/);
  if(!begin)throw Error('Missing drag preview begin');
  text=text.replace(begin[0],begin[0]+'        GraphProbe.began()\n');
  graph=out+'/SessionGroupConversationGraph.swift';
  await writeFile(graph,text);
  if(verifyGraphRefresh) {
    const original=await readFile(model,'utf8'),marker='        let version = try mailbox.dataVersion';
    if(!original.includes(marker))throw Error('Missing graph reader instrumentation point');
    model=out+'/SessionGroupConversationGraphModel.swift';
    await writeFile(model,original.replace(marker,'        GraphReadProbe.shared.check()\n'+marker));
  }
}
const app=['Sources/AutoApproveApp/TerminalNavigator.swift','Sources/AutoApproveApp/TerminalHighlighter.swift','Sources/AutoApproveApp/WindowViewUpdates.swift',graph,...(hasModel?[model]:[]),source];
execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...objects,...app,'Tests/fixtures/session-groups-render.swift','-o',binary],{stdio:'inherit',timeout:180000});
const mode=verifyOpen?'--verify-open':verifyRefresh?'--verify-refresh':verifyDrag?'--verify-drag':verifyGraphRefresh?'--verify-graph-refresh':graphScenes?'--graph':null;
if(mode)console.log(execFileSync(binary,[out,mode],{encoding:'utf8',timeout:300000}).trim());
else if (process.argv.includes('--interactive')) {
  execFileSync(binary,[out,'--interactive'],{stdio:'inherit',timeout:3600000});
} else console.log(execFileSync(binary,[out],{encoding:'utf8',timeout:30000}).trim());
