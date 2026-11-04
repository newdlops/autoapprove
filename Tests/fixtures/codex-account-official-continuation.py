#!/usr/bin/env python3
"""Owned native TUI lifecycle probe; synthetic tokens cannot authenticate.

Invoked by scripts/codex-account-official-continuation-check.mjs. No user
homes, auth files, existing daemons or terminal sessions are mutated.
"""
import argparse, base64, datetime, fcntl, http.server, json, os, pathlib
import pty, re, shutil, signal, socket, struct, subprocess, tempfile, termios
import threading, time
from codex_tui_isolation import IsolationGuard, require_no_production_controller
parser=argparse.ArgumentParser()
parser.add_argument('--cli',required=True)
parser.add_argument('--check',required=True)
parser.add_argument('--different-account',action='store_true')
parser.add_argument('--keep-fixture',action='store_true')
args=parser.parse_args()
require_no_production_controller()
cli=str(pathlib.Path(args.cli).resolve(strict=True))
checker=str(pathlib.Path(args.check).resolve(strict=True))
package=pathlib.Path(cli).parent.parent
assert (package/'bin/codex').resolve()==pathlib.Path(cli), 'Managed Codex package required'
assert (package/'codex-package.json').is_file(), 'Managed package metadata required'
root=pathlib.Path(tempfile.mkdtemp(prefix='aa-account-real-cli-',dir='/private/tmp'))
def synthetic_account(user):
    def enc(value):return base64.urlsafe_b64encode(json.dumps(value).encode()).rstrip(b'=').decode()
    token=enc({'alg':'none','typ':'JWT'})+'.'+enc({'sub':user,'exp':4102444800,'https://api.openai.com/auth':{'chatgpt_user_id':user,'chatgpt_account_id':'fixture-workspace','chatgpt_plan_type':'pro'}})+'.synthetic-invalid-signature'
    # Artificial test tokens only; none can authenticate to a real service.
    data={'auth_mode':'chatgpt','tokens':{'id_token':token,'access_token':token,'refresh_token':'synthetic-invalid-refresh','account_id':'fixture-workspace','login_owner_id':'fixture-login-'+user},'last_refresh':datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00','Z')}
    (root/'auth.json').write_text(json.dumps(data));(root/'auth.json').chmod(0o600)

auth=synthetic_account;auth('fixture-user-a')
new_user='fixture-user-b' if args.different_account else 'fixture-user-a'
counts={'post':0,'blockedExternal':0}
stop_streams=threading.Event()
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self,*args):pass
    def do_CONNECT(self):
        counts['blockedExternal']+=1
        try:self.send_error(502)
        except (BrokenPipeError,ConnectionResetError):pass
    def do_GET(self):
        data=json.dumps({'object':'list','data':[]}).encode();self.send_response(200);self.send_header('Content-Length',str(len(data)));self.end_headers()
        try:self.wfile.write(data)
        except (BrokenPipeError,ConnectionResetError):pass
    def do_POST(self):
        counts['post']+=1
        request_body=self.rfile.read(int(self.headers.get('Content-Length','0')))
        self.send_response(200);self.send_header('Content-Type','text/event-stream');self.send_header('Cache-Control','no-cache');self.end_headers()
        rid='fixture-response-'+str(counts['post'])
        def event(value):
            self.wfile.write(('data: '+json.dumps(value)+'\n\n').encode());self.wfile.flush()
        stream_event=stop_streams
        try:
            event({'type':'response.created','response':{'id':rid,'status':'in_progress','output':[]}})
            event({'type':'response.output_item.added','output_index':0,'item':{'id':rid+'-message','type':'message','role':'assistant','content':[]}})
            event({'type':'response.content_part.added','item_id':rid+'-message','output_index':0,'content_index':0,'part':{'type':'output_text','text':''}})
            event({'type':'response.output_text.delta','item_id':rid+'-message','output_index':0,'content_index':0,'delta':'Owned synthetic task is running.'})
            if b'OWNED_IDLE_CONTROL' in request_body:
                item={'id':rid+'-message','type':'message','role':'assistant','status':'completed','content':[{'type':'output_text','text':'Owned synthetic task is running.'}]}
                event({'type':'response.output_item.done','output_index':0,'item':item})
                event({'type':'response.completed','response':{'id':rid,'status':'completed','output':[item],'usage':{'input_tokens':1,'output_tokens':1,'total_tokens':2}}})
                return
            while not stream_event.wait(.2):self.wfile.write(b': fixture heartbeat\n\n');self.wfile.flush()
        except (BrokenPipeError,ConnectionResetError):pass
http=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler);threading.Thread(target=http.serve_forever,daemon=True).start()
port=http.server_port
env={'HOME':str(root),'CODEX_HOME':str(root),'PATH':'/usr/bin:/bin','NO_COLOR':'1','TERM':'xterm-256color','HTTP_PROXY':f'http://127.0.0.1:{port}','HTTPS_PROXY':f'http://127.0.0.1:{port}','NO_PROXY':'127.0.0.1,localhost'}
installed=root/'packages/app-server-daemon/releases'/package.name
shutil.copytree(package,installed,symlinks=True)
(root/'packages/app-server-daemon/current').symlink_to(pathlib.Path('releases')/package.name)
work=[root/'work-a',root/'work-b',root/'work-c']
for path in work:path.mkdir()
config=f'''model = "fixture-model"
model_provider = "fixture"
check_for_update_on_startup = false
cli_auth_credentials_store = "file"
chatgpt_base_url = "http://127.0.0.1:{port}"

[features]
goals = true
apps = false
plugins = false
[model_providers.fixture]
name = "Fixture"
base_url = "http://127.0.0.1:{port}/v1"
wire_api = "responses"
requires_openai_auth = false
'''+''.join(f'\n[projects."{path}"]\ntrust_level = "trusted"\n' for path in work)
(root/'config.toml').write_text(config)
def command(*args):
    r=subprocess.run([cli,*args],env=env,cwd=root,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=180)
    if r.returncode:raise RuntimeError('Owned CLI command failed: '+r.stderr.decode(errors='replace')[:400])
    return r.stdout
class WS:
    def __init__(self):
        self.s=socket.socket(socket.AF_UNIX);self.s.settimeout(4);self.s.connect(str(root/'app-server-control/app-server-control.sock'))
        key=base64.b64encode(os.urandom(16)).decode();self.s.sendall(f'GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n'.encode())
        head=b''
        while not head.endswith(b'\r\n\r\n'):head+=self.s.recv(1)
        assert b'101'in head
        self.seq=0;self.call('initialize',{'clientInfo':{'name':'autoapprove-isolated-test','version':'1'},'capabilities':{'experimentalApi':True}});self.send({'method':'initialized'})
    def frame(self,code,payload):
        mask=os.urandom(4);length=len(payload);head=bytes([0x80|code,0x80|length])if length<126 else bytes([0x80|code,0xfe])+struct.pack('!H',length)
        self.s.sendall(head+mask+bytes(b^mask[i%4]for i,b in enumerate(payload)))
    def send(self,obj):self.frame(1,json.dumps(obj).encode())
    def read(self,n):
        data=b''
        while len(data)<n:
            chunk=self.s.recv(n-len(data))
            if not chunk:raise RuntimeError('Owned socket EOF')
            data+=chunk
        return data
    def call(self,method,params):
        self.seq+=1;self.send({'id':self.seq,'method':method,'params':params})
        while True:
            a,b=self.read(2);size=b&127
            if size==126:size=struct.unpack('!H',self.read(2))[0]
            elif size==127:size=struct.unpack('!Q',self.read(8))[0]
            mask=self.read(4)if b&128 else None;data=self.read(size)
            if mask:data=bytes(v^mask[i%4]for i,v in enumerate(data))
            if a&15==9:self.frame(10,data);continue
            if a&15!=1:continue
            obj=json.loads(data)
            if obj.get('id')==self.seq:
                if 'error'in obj:raise RuntimeError('Owned server RPC rejected '+method+' '+json.dumps(obj['error']))
                return obj['result']
    def close(self):self.s.close()
children=[];started=False;check=None
ansi=re.compile(rb'\x1b\[[0-?]*[ -/]*[@-~]')
def drain(child,seconds):
    until=time.monotonic()+seconds
    while time.monotonic()<until:
        try:
            data=os.read(child['fd'],65536)
            if data:child['data']+=data
        except BlockingIOError:pass
        except OSError:break
        time.sleep(.015)
def text(child,offset=0):return ansi.sub(b'',child['data'][offset:]).decode(errors='replace')
def snapshot():
    c=WS()
    try:
        account=c.call('accountSession/list',{'refreshWorkspaceMetadata':False})['sessions'][0]['userId']
        loaded=c.call('thread/loaded/list',{'limit':100})
        assert not loaded.get('nextCursor')
        rows=[c.call('thread/read',{'threadId':id,'includeTurns':False})['thread'] for id in loaded['data']]
        return account,{row['id']:{'cwd':row['cwd'],'status':row['status']['type'],'model':row.get('model'),'child':bool(row.get('parentThreadId')),'ephemeral':bool(row.get('ephemeral')),'sourceType':type(row.get('source')).__name__}for row in rows}
    finally:c.close()
isolation=IsolationGuard()
try:
    isolation.start()
    command('app-server','daemon','start');started=True
    version=json.loads(command('app-server','daemon','version'));assert version['backend']=='pid'
    for index,path in enumerate(work):
        pid,fd=pty.fork()
        if pid==0:
            os.chdir(path);os.execve(cli,[cli,'--no-alt-screen','--sandbox','read-only','--ask-for-approval','never','-C',str(path)],env)
        os.set_blocking(fd,False);fcntl.ioctl(fd,termios.TIOCSWINSZ,struct.pack('HHHH',36,120,0,0));os.kill(pid,signal.SIGWINCH)
        child={'pid':pid,'fd':fd,'data':b'','draft':'UNSENT_FIXTURE_DRAFT_'+str(index)};children.append(child);drain(child,2)
    end=time.monotonic()+15
    while True:
        beforeAccount,before=snapshot()
        if len(before)==3:break
        for child in children:drain(child,.2)
        if time.monotonic()>end:
            (root/'startup-private.txt').write_text('\n'.join(text(c)[-4000:]for c in children));raise RuntimeError('Owned TUIs did not load three threads; private diagnostics '+str(root))
    assert beforeAccount=='fixture-user-a';assert all(v['status']=='idle'for v in before.values())
    os.write(children[2]['fd'],b'OWNED_IDLE_CONTROL');drain(children[2],.3)
    os.write(children[2]['fd'],b'\r');drain(children[2],.3)
    deadline=time.monotonic()+20
    while True:
        _,control=snapshot()
        if counts['post']>0 and any(v['cwd']==str(work[2]) and v['status']=='idle' for v in control.values()):break
        for child in children:drain(child,.1)
        if time.monotonic()>deadline:raise AssertionError('Owned idle control did not materialize')
    for child in children[:2]:
        os.write(child['fd'],b'Run the owned synthetic task.');drain(child,.4)
        os.write(child['fd'],b'\r');drain(child,.4)
    deadline=time.monotonic()+20
    while True:
        _,active=snapshot()
        if len([v for v in active.values() if not v['ephemeral'] and not v['child']])==3 and sum(v['status']=='active' and not v['ephemeral'] and not v['child'] for v in active.values())==2:break
        for child in children:drain(child,.1)
        if time.monotonic()>deadline:
            (root/'active-failure-private.txt').write_text('\n'.join(text(c)[-6000:] for c in children))
            print(json.dumps({'root':str(root),'fixtureRequests':counts,'ownedStatus':list(active.values())}),flush=True)
            raise AssertionError('Owned tasks failed to start')
    initial_titles=sum(v['ephemeral'] for v in active.values())
    before={id:value for id,value in active.items() if not value['ephemeral'] and not value['child']}
    goal_control=WS()
    try:
        for id,value in before.items():
            if value['cwd']==str(work[1]):continue
            status='active' if value['cwd']==str(work[0]) else 'paused'
            result=goal_control.call('thread/goal/set',{'threadId':id,'status':status,'objective':'Owned synthetic lifecycle task','tokenBudget':20000,'origin':'user'})
            assert result['goal']['status']==status
    finally:goal_control.close()
    for child in children:
        os.write(child['fd'],child['draft'].encode());drain(child,.5);assert child['draft']in text(child)
        child['offset']=len(child['data'])
    requests_before=counts['post']
    auth(new_user)
    assert snapshot()[0]=='fixture-user-a'
    # Exact owned-home official lifecycle, only after all two owned threads idle.
    check=subprocess.Popen([checker,str(root),cli,('official-switch' if new_user != 'fixture-user-a' else 'official'),*[str(c['pid'])for c in children]],stdout=open(root/'checker-out-private.txt','wb'),stderr=open(root/'checker-error-private.txt','wb'),cwd=root,env=env,start_new_session=True)
    deadline=time.monotonic()+490
    finished_initial_streams=False
    while check.poll() is None and time.monotonic()<deadline:
        if not finished_initial_streams:
            try:
                if json.loads((root/'autoapprove-transition-fixture.json').read_text())['phase']=='restarting':
                    stop_streams.set();stop_streams=threading.Event();finished_initial_streams=True
            except (FileNotFoundError,json.JSONDecodeError):pass
        for child in children:drain(child,.05)
    if check.poll() is None:os.killpg(check.pid,signal.SIGKILL)
    check.wait();output=(root/'checker-out-private.txt').read_bytes();error=(root/'checker-error-private.txt').read_bytes()
    import types
    result=types.SimpleNamespace(returncode=check.returncode,stdout=output,stderr=error)
    if result.returncode:
        for child in children:drain(child,.2)
        (root/'failure-ui-private.txt').write_text('\n'.join(text(c)[-6000:]for c in children))
        print('Owned failure UI: '+str(root),flush=True)
        raise AssertionError(result.stderr.decode()[:1800])
    print(result.stdout.decode(),flush=True)
    end=time.monotonic()+20
    while True:
        try:
            afterAccount,loaded=snapshot()
            after={id:value for id,value in loaded.items() if not value['ephemeral'] and not value['child']}
            if afterAccount==new_user and set(after)==set(before) and sum(v['status']=='active' for v in after.values())==2:break
        except (OSError,RuntimeError):pass
        for child in children:drain(child,.2)
        if time.monotonic()>end:raise RuntimeError('Owned TUIs did not reconnect original thread IDs')
    for child in children:
        assert os.waitpid(child['pid'],os.WNOHANG)==(0,0)
        fcntl.ioctl(child['fd'],termios.TIOCSWINSZ,struct.pack('HHHH',36,119,0,0));os.kill(child['pid'],signal.SIGWINCH);drain(child,1)
        (root/('tui-'+str(child['pid'])+'-private.txt')).write_text(text(child,child['offset']))
        assert child['draft']in text(child,child['offset']),'Draft missing from fresh post-reconnect repaint'
    assert all(before[id]==value for id,value in after.items()),'Retained root thread identity, cwd, model and idle state changed'
    assert counts['post']>=requests_before+2,'Both interrupted conversations must execute a new local fixture request'
    print(json.dumps({'verified':True,'officialCLI':'0.166.0','ownedTUIs':3,'idlePausedControl':True,'originalPIDsRetained':True,'originalThreadIDsRetained':True,'draftsRetainedAfterFreshRepaint':True,'cwdAndActivityRetained':True,'newServerAccountConfirmed':True,'localFixtureRequests':counts['post'],'externalModelCalls':0,'sameAccountRelogin':new_user=='fixture-user-a','differentAccountMetadata':new_user=='fixture-user-b','syntheticAuthOnly':True,'realAuthenticationPerformed':False,'originalActiveTurnsStopped':sum(v['status']=='active' for v in before.values()),'internalTitleJobs':initial_titles,'productionServerTouched':False,'root':str(root)}))
finally:
    isolation.stop()
    if check is not None and check.poll() is None:
        os.killpg(check.pid,signal.SIGKILL);check.wait()
    for child in children:
        try:os.kill(child['pid'],signal.SIGTERM)
        except ProcessLookupError:pass
        try:os.close(child['fd'])
        except OSError:pass
    for child in children:
        try:
            end=time.monotonic()+2
            while time.monotonic()<end and os.waitpid(child['pid'],os.WNOHANG)==(0,0):time.sleep(.05)
            if os.waitpid(child['pid'],os.WNOHANG)==(0,0):os.kill(child['pid'],signal.SIGKILL);os.waitpid(child['pid'],0)
        except ChildProcessError:pass
    stop_streams.set()
    if started:
        try:command('app-server','daemon','stop')
        except Exception:pass
    stop_streams.set();http.shutdown()
    if not args.keep_fixture:shutil.rmtree(root)
