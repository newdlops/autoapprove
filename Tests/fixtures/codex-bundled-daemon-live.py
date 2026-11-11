#!/usr/bin/env python3
"""Exercise app preparation against an empty owned home, never a user daemon."""
import argparse
import ctypes
import hashlib
import json
import os
import pathlib
import secrets
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument('--runtime', required=True)
parser.add_argument('--helper', required=True)
parser.add_argument('--expected-node', required=True)
parser.add_argument('--output', required=True)
args = parser.parse_args()
runtime = pathlib.Path(args.runtime).resolve(strict=True)
binary = runtime/'bin/codex'
manifest = json.loads((runtime/'manifest.json').read_text())
assert manifest['buildLabel'] == 'autoapprove-managed-1671-2'
output = pathlib.Path(args.output)
output.mkdir(mode=0o700)
fixture = pathlib.Path(tempfile.mkdtemp(prefix='aa-managed2-daemon-', dir='/private/tmp'))
home = fixture/'home'
home.mkdir(mode=0o700)
native = pathlib.Path(tempfile.mkdtemp(prefix='aa-nr-', dir='/private/tmp'))
(home/'config.toml').write_text('check_for_update_on_startup=false\ncli_auth_credentials_store="file"\n[features]\napps=false\nplugins=false\n')
(home/'config.toml').chmod(0o600)
env = {'HOME': str(fixture), 'CODEX_HOME': str(home), 'PATH': '/usr/bin:/bin', 'NO_COLOR': '1',
       'AUTOAPPROVE_NATIVE_RUNTIME_ROOT': str(native), 'OTEL_SDK_DISABLED': 'true',
       'HTTP_PROXY': 'http://127.0.0.1:9', 'HTTPS_PROXY': 'http://127.0.0.1:9', 'NO_PROXY': '127.0.0.1,localhost'}
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

def identities():
    with opener.open('http://127.0.0.1:8765/api/state', timeout=4) as response:
        state = json.load(response)
    assert state['id'] == args.expected_node
    return {(r['session']['id'], r['session']['pid'], r['session']['started'], r['session']['tty'])
            for r in state['sessions'] if r['session']['phase'] != 'ended'}

before = identities()

def command(arguments):
    return subprocess.run([str(binary), *arguments], env=env, cwd=home,
                          capture_output=True, text=True, timeout=30)

def prepare(index):
    result = subprocess.run([args.helper, '--bundled-runtime-prepare', str(runtime), str(home)],
                            env=env, cwd=home, capture_output=True, text=True, timeout=110)
    (output/('prepare-'+str(index)+'-private.log')).write_text(result.stdout+result.stderr)
    assert result.returncode == 0, 'App server preparation failed; inspect the private log'
    assert json.loads(result.stdout)['serverPrepared'] is True
    assert before <= identities()

def read_native(path, request, producer, expected_pid):
    with socket.socket(socket.AF_UNIX) as stream:
        stream.settimeout(2)
        stream.connect(str(path))
        token = stream.getsockopt(0, 6, 32)  # macOS LOCAL_PEERTOKEN
        class AuditToken(ctypes.Structure):
            _fields_ = [('words', ctypes.c_uint32*8)]
        bsm = ctypes.CDLL('/usr/lib/libbsm.dylib')
        value = AuditToken.from_buffer_copy(token)
        peer = {}
        for key, method in [('pid', 'pid'), ('auditPidVersion', 'pidversion'), ('effectiveUid', 'euid')]:
            fn = getattr(bsm, 'audit_token_to_'+method)
            fn.argtypes, fn.restype = [AuditToken], ctypes.c_uint32
            peer[key] = fn(value)
        assert peer['pid'] == expected_pid and peer['effectiveUid'] == os.getuid()
        nonce = secrets.token_hex(16)
        stream.sendall(json.dumps({**request, 'nonce': nonce}).encode()+b'\n')
        data = bytearray()
        while not data.endswith(b'\n'):
            chunk = stream.recv(65536)
            assert chunk
            data.extend(chunk)
            assert len(data) <= 1048576
        response = json.loads(data)
        assert response['producer'] == producer and response['pid'] == expected_pid and response['nonce'] == nonce
        assert response['membershipComplete'] is False
        return peer, response

stopped = False
try:
    prepare(1)
    version = command(['app-server', 'daemon', 'version'])
    assert version.returncode == 0, version.stderr
    status = json.loads(version.stdout)
    (output/'version-private.json').write_text(json.dumps(status, indent=2)+'\n')
    assert status['status'] == 'running' and status['backend'] == 'pid'
    assert all(status[k] == '0.167.1' for k in ['cliVersion', 'appServerVersion', 'managedCodexVersion'])
    assert hashlib.sha256(pathlib.Path(status['managedCodexPath']).read_bytes()).hexdigest() == manifest['binarySHA256']
    published = pathlib.Path(status['socketPath']).resolve()
    assert published == (home/'app-server-control/app-server-control.sock').resolve()
    records = list(native.glob('s-*/registration.json'))
    assert len(records) == 1, 'Managed daemon did not forward the private registration root'
    record = json.loads(records[0].read_text())
    assert pathlib.Path(record['home']).resolve() == home.resolve()
    pid = record['pid']
    peer, observed = read_native(records[0].parent/'i.sock', {}, 'autoapprove-native-server-prototype', pid)
    assert observed['cliVersion'] == '0.167.1' and observed['admissionGranted'] is False
    assert record['processIdentity']['auditPidVersion'] == peer['auditPidVersion']
    same_peer, control = read_native(records[0].parent/'c.sock', {'op': 'inspect'}, 'autoapprove-selected-input-lease', pid)
    assert same_peer == peer and control['inputAdmissionPaused'] is False and control['migrationAuthorized'] is False
    prepare(2)
    again = command(['app-server', 'daemon', 'version'])
    assert again.returncode == 0 and json.loads(again.stdout)['status'] == 'running'
    # The version API does not publish a PID. Recheck the same private endpoint
    # and its kernel audit generation instead of treating metadata as liveness.
    assert json.loads(records[0].read_text()) == record, 'Repeated preparation changed the registration'
    same_peer, _ = read_native(records[0].parent/'i.sock', {}, 'autoapprove-native-server-prototype', pid)
    assert same_peer == peer, 'Repeated preparation restarted the server'
    assert before <= identities()
    result = {'verified': True, 'managedServerPID': pid, 'binarySHA256': manifest['binarySHA256'],
              'appPreparationVerified': True, 'runtimeRootForwarded': True, 'nativeKernelPeerVerified': True,
              'selectedControlAvailable': True, 'repeatedPreparationKeptPID': True, 'originalSessions': len(before),
              'migrationVerified': False}
finally:
    stop = command(['app-server', 'daemon', 'stop'])
    (output/'stop-private.log').write_text(stop.stdout+stop.stderr)
    stopped = stop.returncode == 0
    assert stopped, 'Owned daemon stop was not confirmed; private fixture retained at '+str(fixture)
    assert before <= identities(), 'Original controller sessions changed'
    shutil.rmtree(fixture)
    shutil.rmtree(native)

result['ownedDaemonStopped'] = stopped
result['originalSessionsPreservedAfterCleanup'] = True
(output/'report.json').write_text(json.dumps(result, indent=2)+'\n')
print(json.dumps(result))
