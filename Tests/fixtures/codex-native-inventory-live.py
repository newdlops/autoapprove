#!/usr/bin/env python3
"""Read an owned custom TUI's real event-loop inventory; no login or migration.

The test TUI basename must not be codex/claude, so production discovery cannot
classify it as a user agent. A live controller read verifies exclusion and
preservation of the original process/session identities throughout the probe.
"""
import argparse
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
import termios
import threading
import time
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument('--tui', required=True)
parser.add_argument('--expected-node', required=True)
parser.add_argument('--output', required=True)
args = parser.parse_args()
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
        self.send_error(502, 'This read-only fixture never submits a turn')

http = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=http.serve_forever, daemon=True).start()
port = http.server_port
(fixture_home/'config.toml').write_text(f'''model = "fixture-model"
model_provider = "fixture"
check_for_update_on_startup = false
daemon_auto_start = false
cli_auth_credentials_store = "file"
chatgpt_base_url = "http://127.0.0.1:{port}"
[analytics]
enabled = false
[features]
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
''')
(fixture_home/'config.toml').chmod(0o600)
env = {'HOME': str(fixture_home), 'CODEX_HOME': str(fixture_home), 'PATH': '/usr/bin:/bin',
       'TERM': 'xterm-256color', 'NO_COLOR': '1', 'OTEL_SDK_DISABLED': 'true',
       'AUTOAPPROVE_NATIVE_INVENTORY_SOCKET': str(endpoint),
       'HTTP_PROXY': f'http://127.0.0.1:{port}', 'HTTPS_PROXY': f'http://127.0.0.1:{port}',
       'NO_PROXY': '127.0.0.1,localhost'}
pid, fd = pty.fork()
if pid == 0:
    os.chdir(work)
    os.execve(str(tui), [str(tui), '--no-daemon', '--no-alt-screen', '--sandbox', 'read-only',
                        '--ask-for-approval', 'never', '-C', str(work)], env)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 36, 120, 0, 0))
os.set_blocking(fd, False)
done = threading.Event()
captured = bytearray()
capture_lock = threading.Lock()
reaped = False

def pump():
    pending = b''
    replies = [(b'\x1b[6n', b'\x1b[1;1R'), (b'\x1b[c', b'\x1b[?1;2c'),
               (b'\x1b[>c', b'\x1b[>0;0;0c'), (b'\x1b[?u', b'\x1b[?0u'),
               (b'\x1b]10;?\x07', b'\x1b]10;rgb:ffff/ffff/ffff\x07'),
               (b'\x1b]11;?\x07', b'\x1b]11;rgb:0000/0000/0000\x07')]
    replies.extend([(b'\x1b]10;?\x1b\\', b'\x1b]10;rgb:ffff/ffff/ffff\x1b\\'),
                    (b'\x1b]11;?\x1b\\', b'\x1b]11;rgb:0000/0000/0000\x1b\\')])
    while not done.is_set():
        try:
            if not select.select([fd], [], [], .05)[0]:
                continue
            data = os.read(fd, 65536)
            if not data:
                break
            with capture_lock:
                captured.extend(data)
            pending += data
            for query, reply in replies:
                while query in pending:
                    pending = pending.replace(query, b'', 1)
                    os.write(fd, reply)
            pending = pending[-32:]
        except (OSError, BlockingIOError):
            break

reader = threading.Thread(target=pump, daemon=True)
reader.start()

def inventory():
    info = endpoint.lstat()
    assert stat.S_ISSOCK(info.st_mode) and info.st_uid == os.getuid() and info.st_mode & 0o077 == 0
    nonce = secrets.token_hex(16)
    with socket.socket(socket.AF_UNIX) as stream:
        stream.settimeout(3)
        stream.connect(str(endpoint))
        stream.sendall(json.dumps({'nonce': nonce}).encode()+b'\n')
        data = bytearray()
        while not data.endswith(b'\n'):
            chunk = stream.recv(65536)
            assert chunk, 'Inventory socket closed before a complete reply'
            data.extend(chunk)
            assert len(data) <= 1024*1024
    value = json.loads(data)
    assert value['nonce'] == nonce and value['pid'] == pid and value['schemaVersion'] == 1
    assert value['producer'] == 'autoapprove-native-tui-prototype'
    assert value['membershipComplete'] is False and value['admissionGranted'] is False
    return value

def original_sessions_unchanged():
    state = controller()
    assert before <= identities(state), 'Original controller session identities changed'
    assert all(row['session']['pid'] != pid for row in state['sessions']), 'Fixture entered production discovery'

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
    assert counts['inference'] == 0, 'Read-only probe unexpectedly submitted a turn'
    result = {'verified': True, 'nativeTUIProducer': True, 'fixturePID': pid,
              'originalSessions': len(before), 'preserved': len(before), 'fixtureExcludedFromController': True,
              'primaryIdentityPreserved': True, 'exactDraftPreservedOnFreshRepaint': True,
              'draftContentNotExported': True, 'inferenceRequests': 0,
              'externalRequestsBlocked': counts['externalBlocked'], 'membershipComplete': False,
              'admissionGranted': False, 'migrationVerified': False}
    (output/'report.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(result))
except BaseException:
    with capture_lock:
        (output/'owned-tui-failure-private.bin').write_bytes(captured)
    raise
finally:
    if not reaped:
        ended, _ = os.waitpid(pid, os.WNOHANG)
        if not ended:
            os.killpg(pid, signal.SIGTERM)
            until = time.monotonic()+3
            while time.monotonic() < until:
                ended, _ = os.waitpid(pid, os.WNOHANG)
                if ended:
                    break
                time.sleep(.05)
            if not ended:
                os.killpg(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
    done.set()
    reader.join(timeout=1)
    os.close(fd)
    http.shutdown()
    http.server_close()
    shutil.rmtree(fixture)
