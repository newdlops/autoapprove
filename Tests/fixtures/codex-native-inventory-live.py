#!/usr/bin/env python3
"""Read an owned custom TUI's real event-loop inventory; no login or migration.

The test TUI basename must not be codex/claude, so production discovery cannot
classify it as a user agent. A live controller read verifies exclusion and
preservation of the original process/session identities throughout the probe.
"""
import argparse
import base64
import fcntl
import http.server
import json
import os
import pathlib
import pty
import re
import secrets
import select
import shutil
import signal
import socket
import stat
import struct
import subprocess
import termios
import threading
import time
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument('--tui', required=True)
parser.add_argument('--expected-node', required=True)
parser.add_argument('--output', required=True)
parser.add_argument('--server', help='Optional exact-version CLI for an owned shared Unix app-server')
parser.add_argument('--navigation', action='store_true', help='Exercise owned offscreen unsubscribe and draft return')
parser.add_argument('--return-via-resume', action='store_true', help='Regression check for the distinct direct /resume path')
parser.add_argument('--peer-cli', help='Optional patched full CLI for a second owned TUI on the same root')
args = parser.parse_args()
assert not args.navigation or args.server, 'Navigation requires the owned shared server'
assert not args.return_via_resume or args.navigation, 'Direct return requires navigation'
assert not args.peer_cli or args.navigation, 'A shared peer requires the owned navigation test'
tui = pathlib.Path(args.tui).resolve(strict=True)
assert tui.name == 'codex-tui', 'Only the explicitly built standalone test TUI is allowed'
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

def controller():
    with opener.open('http://127.0.0.1:8765/api/state', timeout=4) as response:
        value = json.load(response)
    assert value['id'] == args.expected_node, 'Wrong local controller'
    return value

def identities(value):
    return {(row['session']['id'], row['session']['pid'], row['session']['started'], row['session']['tty'])
            for row in value['sessions'] if row['session']['phase'] != 'ended'}

before = identities(controller())
output = pathlib.Path(args.output).resolve()
output.mkdir(parents=True, exist_ok=True, mode=0o700)
fixture = pathlib.Path(__import__('tempfile').mkdtemp(prefix='aa-native-ui-', dir='/private/tmp'))
fixture.chmod(0o700)
fixture_home, work = fixture/'home', fixture/'work'
fixture_home.mkdir(mode=0o700)
work.mkdir(mode=0o700)
endpoint = fixture/'inventory.sock'
counts = {'inference': 0, 'externalBlocked': 0}

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *unused):
        pass

    def do_CONNECT(self):
        counts['externalBlocked'] += 1
        self.send_error(502)

    def do_GET(self):
        if self.path.startswith(('http://', 'https://')):
            counts['externalBlocked'] += 1
            self.send_error(502)
            return
        data = b'{"object":"list","data":[]}'
        self.send_response(200)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', '0')))
        counts['inference'] += 1
        if args.navigation:
            rid = 'owned-inventory-response-'+str(counts['inference'])
            item = {'id': rid+'-message', 'type': 'message', 'role': 'assistant', 'status': 'completed',
                    'content': [{'type': 'output_text', 'text': 'Owned local inventory fixture.', 'annotations': []}]}
            events = [{'type': 'response.created', 'response': {'id': rid, 'status': 'in_progress', 'output': []}},
                      {'type': 'response.output_item.added', 'output_index': 0, 'item': item},
                      {'type': 'response.output_item.done', 'output_index': 0, 'item': item},
                      {'type': 'response.completed', 'response': {'id': rid, 'status': 'completed', 'output': [item],
                                                                 'usage': {'input_tokens': 1, 'output_tokens': 1, 'total_tokens': 2}}}]
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Connection', 'close')
            self.end_headers()
            for event in events:
                self.wfile.write(('data: '+json.dumps(event)+'\n\n').encode())
            return
        self.send_error(502, 'This read-only fixture never submits a turn')

http = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=http.serve_forever, daemon=True).start()
port = http.server_port
(fixture_home/'config.toml').write_text(f'''model = "fixture-model"
model_provider = "fixture"
check_for_update_on_startup = false
cli_auth_credentials_store = "file"
chatgpt_base_url = "http://127.0.0.1:{port}"
[analytics]
enabled = false
[features]
daemon_auto_start = false
apps = false
plugins = false
[model_providers.fixture]
name = "Owned fixture"
base_url = "http://127.0.0.1:{port}/v1"
wire_api = "responses"
requires_openai_auth = false
supports_websockets = false
[projects."{work}"]
trust_level = "trusted"
[tui.keymap.global]
open_agents = "f12"
''')
(fixture_home/'config.toml').chmod(0o600)
env = {'HOME': str(fixture_home), 'CODEX_HOME': str(fixture_home), 'PATH': '/usr/bin:/bin',
       'TERM': 'xterm-256color', 'NO_COLOR': '1', 'OTEL_SDK_DISABLED': 'true',
       'AUTOAPPROVE_NATIVE_INVENTORY_SOCKET': str(endpoint),
       'HTTP_PROXY': f'http://127.0.0.1:{port}', 'HTTPS_PROXY': f'http://127.0.0.1:{port}',
       'NO_PROXY': '127.0.0.1,localhost'}
server = None
server_log = None
control_socket = fixture_home/'app-server-control/app-server-control.sock'
backend_socket = fixture/'backend.sock'
proxy_listener = None
proxy_done = threading.Event()
proxy_threads = []
unsubscribes = []

def proxy_connection(client):
    """Forward only owned test traffic; retain unsubscribe metadata, never text."""
    backend = socket.socket(socket.AF_UNIX)
    backend.settimeout(4)
    backend.connect(str(backend_socket))
    buffers = {client: bytearray(), backend: bytearray()}
    headers = {client: False, backend: False}
    pending = {}

    def observe(stream, data):
        buffer = buffers[stream]
        buffer.extend(data)
        assert len(buffer) <= 1024*1024
        if not headers[stream]:
            end = buffer.find(b'\r\n\r\n')
            if end < 0:
                return
            del buffer[:end+4]
            headers[stream] = True
        while len(buffer) >= 2:
            a, b = buffer[:2]
            size, offset = b & 127, 2
            if size in (126, 127):
                length = 2 if size == 126 else 8
                if len(buffer) < 2+length:
                    return
                size = int.from_bytes(buffer[2:2+length], 'big')
                offset += length
            assert size <= 1024*1024
            mask_size = 4 if b & 128 else 0
            if len(buffer) < offset+mask_size+size:
                return
            mask = buffer[offset:offset+mask_size]
            payload = bytes(buffer[offset+mask_size:offset+mask_size+size])
            del buffer[:offset+mask_size+size]
            if a & 15 != 1:
                continue
            assert a & 0x80, 'Owned fixture does not accept fragmented JSON observations'
            if mask:
                payload = bytes(v ^ mask[i % 4] for i, v in enumerate(payload))
            value = json.loads(payload)
            if stream is client and value.get('method') == 'thread/unsubscribe':
                entry = {'threadID': value['params']['threadId'], 'acknowledged': False}
                pending[value['id']] = entry
                unsubscribes.append(entry)
            elif stream is backend and value.get('id') in pending and 'method' not in value:
                pending[value['id']]['acknowledged'] = 'result' in value and 'error' not in value

    try:
        while not proxy_done.is_set():
            readable, _, _ = select.select([client, backend], [], [], .1)
            for stream in readable:
                data = stream.recv(65536)
                if not data:
                    return
                observe(stream, data)
                (backend if stream is client else client).sendall(data)
    finally:
        client.close()
        backend.close()

def accept_proxy():
    while not proxy_done.is_set():
        try:
            client, _ = proxy_listener.accept()
        except socket.timeout:
            continue
        except OSError:
            return
        worker = threading.Thread(target=proxy_connection, args=(client,), daemon=True)
        proxy_threads.append(worker)
        worker.start()

class Wire:
    """Owned observer connection; reads never subscribe or submit a turn."""
    def __init__(self):
        self.stream = socket.socket(socket.AF_UNIX)
        self.stream.settimeout(4)
        self.stream.connect(str(control_socket))
        key = base64.b64encode(os.urandom(16)).decode()
        self.stream.sendall(('GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n'
                             'Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n'
                             f'Sec-WebSocket-Key: {key}\r\n\r\n').encode())
        head = bytearray()
        while not head.endswith(b'\r\n\r\n'):
            head.extend(self.read(1))
            assert len(head) < 8192
        assert head.startswith(b'HTTP/1.1 101')
        self.seq = 0
        self.call('initialize', {'clientInfo': {'name': 'owned-inventory-observer', 'version': '1'},
                                 'capabilities': {'experimentalApi': True}})
        self.send({'method': 'initialized'})

    def read(self, size):
        data = bytearray()
        while len(data) < size:
            part = self.stream.recv(size-len(data))
            assert part, 'Owned server closed its observer socket'
            data.extend(part)
        return bytes(data)

    def frame(self, code, data):
        size, mask = len(data), os.urandom(4)
        header = bytes([0x80 | code, 0x80 | size]) if size < 126 else bytes([0x80 | code, 0xfe])+struct.pack('!H', size)
        self.stream.sendall(header+mask+bytes(v ^ mask[i % 4] for i, v in enumerate(data)))

    def send(self, value):
        self.frame(1, json.dumps(value).encode())

    def call(self, method, params):
        self.seq += 1
        self.send({'id': self.seq, 'method': method, 'params': params})
        while True:
            a, b = self.read(2)
            size = b & 127
            if size == 126:
                size = struct.unpack('!H', self.read(2))[0]
            elif size == 127:
                size = struct.unpack('!Q', self.read(8))[0]
            assert size <= 1024*1024
            mask = self.read(4) if b & 128 else None
            data = self.read(size)
            if mask:
                data = bytes(v ^ mask[i % 4] for i, v in enumerate(data))
            if a & 15 == 9:
                self.frame(10, data)
                continue
            if a & 15 != 1:
                continue
            value = json.loads(data)
            if value.get('id') == self.seq:
                assert 'error' not in value, f'Owned read rejected: {method}'
                return value['result']

    def close(self):
        self.stream.close()

if args.server:
    # Copy only into our exclusive test directory, with a basename excluded from
    # production discovery. Never run daemon start or mutate a real package.
    source_server = pathlib.Path(args.server).resolve(strict=True)
    server_path = fixture/'owned-inventory-server'
    shutil.copyfile(source_server, server_path)
    server_path.chmod(0o700)
    version = subprocess.run([str(server_path), '--version'], env=env, cwd=work,
                             capture_output=True, timeout=10, check=True)
    assert version.stdout.strip() == b'codex-cli 0.166.0'
    control_socket.parent.mkdir(mode=0o700)
    server_log = (output/'owned-server-private.log').open('wb')
    server = subprocess.Popen([str(server_path), 'app-server', '--listen', 'unix://'+str(backend_socket)],
                              env=env, cwd=work, stdin=subprocess.DEVNULL,
                              stdout=server_log, stderr=server_log, start_new_session=True)
    deadline = time.monotonic()+15
    while not backend_socket.exists():
        if server.poll() is not None or time.monotonic() > deadline:
            if server.poll() is None:
                os.killpg(server.pid, signal.SIGTERM)
                server.wait(timeout=5)
            http.shutdown()
            server_log.close()
            raise RuntimeError('Owned shared server did not start; inspect its private log')
        time.sleep(.05)
    proxy_listener = socket.socket(socket.AF_UNIX)
    proxy_listener.bind(str(control_socket))
    control_socket.chmod(0o600)
    proxy_listener.listen(10)
    proxy_listener.settimeout(.2)
    proxy_acceptor = threading.Thread(target=accept_proxy, daemon=True)
    proxy_acceptor.start()

pid, fd = pty.fork()
if pid == 0:
    os.chdir(work)
    mode = [] if server else ['--no-daemon']
    os.execve(str(tui), [str(tui), *mode, '--no-alt-screen', '--sandbox', 'read-only',
                        '--ask-for-approval', 'never', '-C', str(work)], env)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 36, 120, 0, 0))
os.set_blocking(fd, False)
done = threading.Event()
captured = bytearray()
capture_lock = threading.Lock()
reaped = False
peer = None

def pump(own_fd, own_capture, own_lock, own_done):
    pending = b''
    replies = [(b'\x1b[6n', b'\x1b[1;1R'), (b'\x1b[c', b'\x1b[?1;2c'),
               (b'\x1b[>c', b'\x1b[>0;0;0c'), (b'\x1b[?u', b'\x1b[?0u'),
               (b'\x1b]10;?\x07', b'\x1b]10;rgb:ffff/ffff/ffff\x07'),
               (b'\x1b]11;?\x07', b'\x1b]11;rgb:0000/0000/0000\x07')]
    replies.extend([(b'\x1b]10;?\x1b\\', b'\x1b]10;rgb:ffff/ffff/ffff\x1b\\'),
                    (b'\x1b]11;?\x1b\\', b'\x1b]11;rgb:0000/0000/0000\x1b\\')])
    while not own_done.is_set():
        try:
            if not select.select([own_fd], [], [], .05)[0]:
                continue
            data = os.read(own_fd, 65536)
            if not data:
                break
            with own_lock:
                own_capture.extend(data)
            pending += data
            for query, reply in replies:
                while query in pending:
                    pending = pending.replace(query, b'', 1)
                    os.write(own_fd, reply)
            pending = pending[-32:]
        except (OSError, BlockingIOError):
            break

reader = threading.Thread(target=pump, args=(fd, captured, capture_lock, done), daemon=True)
reader.start()

def inventory(own_endpoint=endpoint, own_pid=pid):
    info = own_endpoint.lstat()
    assert stat.S_ISSOCK(info.st_mode) and info.st_uid == os.getuid() and info.st_mode & 0o077 == 0
    nonce = secrets.token_hex(16)
    with socket.socket(socket.AF_UNIX) as stream:
        stream.settimeout(3)
        stream.connect(str(own_endpoint))
        stream.sendall(json.dumps({'nonce': nonce}).encode()+b'\n')
        data = bytearray()
        while not data.endswith(b'\n'):
            chunk = stream.recv(65536)
            assert chunk, 'Inventory socket closed before a complete reply'
            data.extend(chunk)
            assert len(data) <= 1024*1024
    value = json.loads(data)
    assert value['nonce'] == nonce and value['pid'] == own_pid and value['schemaVersion'] == 1
    assert value['producer'] == 'autoapprove-native-tui-prototype'
    assert value['membershipComplete'] is False and value['admissionGranted'] is False
    return value

def original_sessions_unchanged():
    state = controller()
    assert before <= identities(state), 'Original controller session identities changed'
    assert all(row['session']['pid'] != pid for row in state['sessions']), 'Fixture entered production discovery'
    if server:
        assert server.poll() is None, 'Owned shared server exited'
        assert all(row['session']['pid'] != server.pid for row in state['sessions'])
    if peer:
        assert all(row['session']['pid'] != peer['pid'] for row in state['sessions'])

def local_owners(value):
    # Catalog metadata is deliberately excluded: visiting the overview does not
    # make every listed conversation this client's retained owner.
    return set(value['retainedInputs']) | {
        identifier for name, values in value['stores'].items() if name != 'catalogReferences'
        for identifier in values
    }

def launch_peer(primary):
    peer_binary = fixture/'owned-inventory-cli'
    shutil.copyfile(pathlib.Path(args.peer_cli).resolve(strict=True), peer_binary)
    peer_binary.chmod(0o700)
    version = subprocess.run([str(peer_binary), '--version'], env=env, cwd=work,
                             capture_output=True, timeout=10, check=True)
    assert version.stdout.strip() == b'codex-cli 0.166.0'
    peer_endpoint = fixture/'peer.sock'
    peer_env = dict(env, AUTOAPPROVE_NATIVE_INVENTORY_SOCKET=str(peer_endpoint))
    peer_pid, peer_fd = pty.fork()
    if peer_pid == 0:
        os.chdir(work)
        os.execve(str(peer_binary), [str(peer_binary), '--no-alt-screen', '--sandbox', 'read-only',
                                    '--ask-for-approval', 'never', '-C', str(work), 'resume', primary], peer_env)
    fcntl.ioctl(peer_fd, termios.TIOCSWINSZ, struct.pack('HHHH', 36, 120, 0, 0))
    os.set_blocking(peer_fd, False)
    value = {'pid': peer_pid, 'fd': peer_fd, 'endpoint': peer_endpoint, 'captured': bytearray(),
             'done': threading.Event(), 'lock': threading.Lock(), 'reaped': False}
    value['reader'] = threading.Thread(target=pump, args=(peer_fd, value['captured'], value['lock'], value['done']), daemon=True)
    value['reader'].start()
    return value

def peer_inventory():
    ended, _ = os.waitpid(peer['pid'], os.WNOHANG)
    if ended:
        peer['reaped'] = True
        raise RuntimeError('Owned peer TUI exited')
    return inventory(peer['endpoint'], peer['pid'])

def stop_owned_tui(own_pid, own_fd, own_done, own_reader, already_reaped):
    if not already_reaped:
        ended, _ = os.waitpid(own_pid, os.WNOHANG)
        if not ended:
            os.killpg(own_pid, signal.SIGTERM)
            until = time.monotonic()+3
            while time.monotonic() < until:
                ended, _ = os.waitpid(own_pid, os.WNOHANG)
                if ended:
                    break
                time.sleep(.05)
            if not ended:
                os.killpg(own_pid, signal.SIGKILL)
                os.waitpid(own_pid, 0)
    own_done.set()
    own_reader.join(timeout=1)
    os.close(own_fd)

def shared_identity(primary):
    if not server:
        return
    wire = Wire()
    try:
        loaded = wire.call('thread/loaded/list', {'limit': 100})
        assert not loaded.get('nextCursor')
        assert set(primary) <= set(loaded['data']), 'Inventory did not match the actual shared server runtime'
        row = wire.call('thread/read', {'threadId': primary[0], 'includeTurns': False})['thread']
        assert row['id'] == primary[0] and row['cwd'] == str(work)
        assert row['status']['type'] == 'idle'
    finally:
        wire.close()

try:
    limit = time.monotonic()+25
    first = None
    while time.monotonic() < limit:
        original_sessions_unchanged()
        ended, _ = os.waitpid(pid, os.WNOHANG)
        if ended:
            reaped = True
            raise RuntimeError('Owned TUI exited before inventory became ready')
        if endpoint.exists():
            try:
                first = inventory()
                if first['stores']['primary'] and not first['currentWidget']['hasActiveView']:
                    break
            except (OSError, AssertionError):
                pass
        time.sleep(.1)
    else:
        raise RuntimeError('Owned TUI did not expose a ready primary thread')
    shared_identity(first['stores']['primary'])
    if args.navigation:
        os.write(fd, b'OWNED_INVENTORY_MATERIALIZE')
        time.sleep(.2)
        os.write(fd, b'\r')
        deadline = time.monotonic()+20
        while time.monotonic() < deadline:
            wire = Wire()
            try:
                row = wire.call('thread/read', {'threadId': first['stores']['primary'][0], 'includeTurns': False})['thread']
                if counts['inference'] and row['status']['type'] == 'idle':
                    row = wire.call('thread/read', {'threadId': first['stores']['primary'][0], 'includeTurns': True})['thread']
            finally:
                wire.close()
            if counts['inference'] and row.get('turns') and row['status']['type'] == 'idle':
                break
            time.sleep(.1)
        else:
            raise RuntimeError('Owned materialized thread did not finish')
    if args.peer_cli:
        peer = launch_peer(first['stores']['primary'][0])
        deadline = time.monotonic()+25
        while time.monotonic() < deadline:
            original_sessions_unchanged()
            try:
                peer_state = peer_inventory()
                if peer_state['stores']['primary'] == first['stores']['primary'] and not peer_state['currentWidget']['hasActiveView']:
                    break
            except OSError:
                pass
            time.sleep(.1)
        else:
            raise RuntimeError('Owned peer did not expose the shared primary root')
        assert first['stores']['primary'][0] in local_owners(peer_state)
        shared_identity(peer_state['stores']['primary'])
    draft = b'UNSENT_NATIVE_INVENTORY_DRAFT_8e932b'
    os.write(fd, draft)
    limit = time.monotonic()+5
    while time.monotonic() < limit:
        current = inventory()
        if current['currentWidget']['hasDraft']:
            break
        time.sleep(.05)
    assert current['currentWidget']['hasDraft'], 'Owned draft was not visible to native producer'
    for _ in range(3):
        value = inventory()
        assert value['stores']['primary'] == first['stores']['primary']
        assert value['currentWidget']['hasDraft']
        assert draft.decode() not in json.dumps(value), 'Draft content escaped inventory'
        original_sessions_unchanged()
        shared_identity(value['stores']['primary'])
        if peer:
            assert peer_inventory()['stores']['primary'] == first['stores']['primary']
    with capture_lock:
        offset = len(captured)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 36, 119, 0, 0))
    os.kill(pid, signal.SIGWINCH)
    time.sleep(.5)
    with capture_lock:
        fresh = bytes(captured[offset:])
    fresh = re.sub(rb'\x1b\][^\x07]*(?:\x07|\x1b\\)', b'', fresh)
    fresh = re.sub(rb'\x1b\[[0-?]*[ -/]*[@-~]', b'', fresh)
    assert draft in fresh, 'Fresh repaint did not retain the exact owned draft'
    offscreen = False
    returned = False
    if args.navigation:
        original = first['stores']['primary'][0]
        os.write(fd, b'\x1b[24~')  # configured F12, not a user Terminal shortcut
        deadline = time.monotonic()+5
        while time.monotonic() < deadline:
            if inventory()['currentWidget']['hasActiveView']:
                break
            time.sleep(.05)
        else:
            raise RuntimeError('Owned overview did not open')
        os.write(fd, b'n')
        deadline = time.monotonic()+15
        while time.monotonic() < deadline:
            parked = inventory()
            if len(parked['stores']['primary']) == 1 and parked['stores']['primary'] != [original] and not parked['currentWidget']['hasActiveView']:
                break
            time.sleep(.05)
        else:
            raise RuntimeError('Owned overview did not navigate to a new thread')
        (output/'owned-parked-inventory.json').write_text(json.dumps(parked, indent=2)+'\n')
        assert original in parked['stores']['overviewInput'], 'Retained local owner was omitted'
        assert original not in parked['stores']['listeners'], 'Old listener remained subscribed'
        assert parked['retainedInputs'][original]['hasDraft'], 'Offscreen draft disappeared'
        assert draft.decode() not in json.dumps(parked)
        offscreen = True
        original_sessions_unchanged()
        assert any(v['threadID'] == original and v['acknowledged'] for v in unsubscribes), 'No actual unsubscribe ACK for the retained root'
        shared_owners = 1
        if peer:
            peer_parked = peer_inventory()
            assert peer_parked['stores']['primary'] == [original]
            assert original in local_owners(parked) and original in local_owners(peer_parked)
            shared_owners = 2
            (output/'owned-peer-inventory.json').write_text(json.dumps(peer_parked, indent=2)+'\n')
        # The overview owns/restores parked input. A direct /resume takes a
        # different upstream path and is not evidence of that preservation.
        if args.return_via_resume:
            os.write(fd, ('/resume '+original).encode())
        else:
            os.write(fd, b'\x1b[24~')
            deadline = time.monotonic()+5
            while time.monotonic() < deadline:
                if inventory()['currentWidget']['hasActiveView']:
                    break
                time.sleep(.05)
            else:
                raise RuntimeError('Owned overview did not reopen')
            os.write(fd, b'/')
            time.sleep(.1)
            os.write(fd, b'OWNED_INVENTORY_MATERIALIZE')
        time.sleep(.2)
        os.write(fd, b'\r')
        deadline = time.monotonic()+15
        while time.monotonic() < deadline:
            value = inventory()
            if value['stores']['primary'] == [original] and value['currentWidget']['hasDraft'] and not value['currentWidget']['hasActiveView']:
                break
            time.sleep(.05)
        else:
            (output/'owned-return-inventory.json').write_text(json.dumps(value, indent=2)+'\n')
            raise RuntimeError('Owned original thread and draft did not return')
        with capture_lock:
            offset = len(captured)
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 36, 118, 0, 0))
        os.kill(pid, signal.SIGWINCH)
        time.sleep(.5)
        with capture_lock:
            repaint = bytes(captured[offset:])
        repaint = re.sub(rb'\x1b\[[0-?]*[ -/]*[@-~]', b'', repaint)
        assert draft in repaint, 'Returning to the original root lost the exact draft'
        returned = True
        original_sessions_unchanged()
        if peer:
            assert peer_inventory()['stores']['primary'] == [original]
    else:
        assert counts['inference'] == 0, 'Read-only probe unexpectedly submitted a turn'
        assert not unsubscribes, 'Read-only probe unexpectedly unsubscribed a thread'
    result = {'verified': True, 'nativeTUIProducer': True, 'fixturePID': pid,
              'originalSessions': len(before), 'preserved': len(before), 'fixtureExcludedFromController': True,
              'primaryIdentityPreserved': True, 'exactDraftPreservedOnFreshRepaint': True,
              'draftContentNotExported': True, 'inferenceRequests': counts['inference'],
              'offscreenUnsubscribedDraftObserved': offscreen, 'exactDraftReturnedAfterNavigation': returned,
              'unsubscribeACKObserved': any(v['acknowledged'] for v in unsubscribes),
              'unsubscribeRequests': len(unsubscribes),
              'ownedWireProxy': server is not None,
              'sampledClients': 2 if peer else 1,
              'sampledOwnersAfterUnsubscribe': shared_owners if args.navigation else None,
              'returnRoute': ('direct-resume' if args.return_via_resume else 'overview') if args.navigation else None,
              'externalRequestsBlocked': counts['externalBlocked'], 'membershipComplete': False,
              'sharedUnixAppServer': server is not None, 'managedDaemonSupervisor': False,
              'admissionGranted': False, 'migrationVerified': False}
except BaseException:
    with capture_lock:
        (output/'owned-tui-failure-private.bin').write_bytes(captured)
    if peer:
        with peer['lock']:
            (output/'owned-peer-failure-private.bin').write_bytes(peer['captured'])
    raise
finally:
    if peer:
        stop_owned_tui(peer['pid'], peer['fd'], peer['done'], peer['reader'], peer['reaped'])
    stop_owned_tui(pid, fd, done, reader, reaped)
    http.shutdown()
    http.server_close()
    if server:
        proxy_done.set()
        proxy_listener.close()
        proxy_acceptor.join(timeout=1)
        for worker in proxy_threads:
            worker.join(timeout=1)
        if server.poll() is None:
            os.killpg(server.pid, signal.SIGTERM)
            try:
                server.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(server.pid, signal.SIGKILL)
                server.wait(timeout=3)
        server_log.close()
    shutil.rmtree(fixture)

# Verify again after terminating only owned children and removing only the owned
# fixture. A successful snapshot before cleanup is insufficient for this claim.
assert before <= identities(controller()), 'Original controller identities changed after fixture cleanup'
result['originalSessionsPreservedAfterCleanup'] = True
(output/'report.json').write_text(json.dumps(result, indent=2)+'\n')
print(json.dumps(result))
