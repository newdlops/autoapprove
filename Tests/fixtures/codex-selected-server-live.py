#!/usr/bin/env python3
"""Owned stdio servers only; no model turns or production homes are used."""
import argparse
import json
import os
import pathlib
import secrets
import select
import socket
import subprocess
import tempfile
import time


class Server:
    def __init__(self, binary, root, config=None, standalone=False):
        self.root = root
        self.home = root / 'home'
        self.home.mkdir(mode=0o700)
        if config:
            (self.home / 'config.toml').write_text(config)
        self.endpoint = root / 'lease.sock'
        env = {k: v for k, v in os.environ.items()
               if not any(s in k.upper() for s in ('TOKEN', 'API_KEY', 'CODEX', 'OPENAI'))}
        env.update(HOME=str(root), CODEX_HOME=str(self.home), AUTOAPPROVE_SELECTED_TRANSITION_SOCKET=str(self.endpoint),
                   HTTP_PROXY='http://127.0.0.1:9', HTTPS_PROXY='http://127.0.0.1:9', NO_PROXY='127.0.0.1,localhost')
        self.log = (root / 'server.log').open('wb')
        self.process = subprocess.Popen([str(binary)] + ([] if standalone else ['app-server']), env=env, cwd=root,
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log)
        self.seq = 0
        self.buffer = b''
        try:
            self.call('initialize', {'clientInfo': {'name': 'owned-selected-probe', 'version': '1'},
                                     'capabilities': {'experimentalApi': True}})
            self.process.stdin.write(b'{"method":"initialized"}\n')
            self.process.stdin.flush()
            end = time.monotonic() + 10
            while not self.endpoint.exists():
                assert self.process.poll() is None and time.monotonic() < end, 'lease endpoint missing'
                time.sleep(.02)
        except BaseException:
            self.close()
            raise

    def call(self, method, params, error=False):
        self.seq += 1
        self.process.stdin.write(json.dumps({'id': self.seq, 'method': method, 'params': params}).encode() + b'\n')
        self.process.stdin.flush()
        end = time.monotonic() + 10
        while True:
            while b'\n' not in self.buffer:
                assert time.monotonic() < end, method + ' timed out'
                ready, _, _ = select.select([self.process.stdout], [], [], .1)
                if ready:
                    data = os.read(self.process.stdout.fileno(), 65536)
                    assert data, 'server exited'
                    self.buffer += data
            line, self.buffer = self.buffer.split(b'\n', 1)
            value = json.loads(line)
            if value.get('id') != self.seq:
                continue
            assert ('error' in value) == error, value
            return value['error' if error else 'result']

    def close(self):
        self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
        self.log.close()


class Lease:
    def __init__(self, endpoint, ids):
        self.socket = socket.socket(socket.AF_UNIX)
        self.socket.settimeout(5)
        self.socket.connect(str(endpoint))
        self.file = self.socket.makefile('rwb', buffering=0)
        self.generation = None
        self.id = None
        self.generation = self.call('inspect')['serverGeneration']
        held = self.call('pause', threadIds=ids)
        self.id = held['leaseId']
        assert held['inputAdmissionPaused'] and not held['migrationAuthorized']
        assert set(held['threadIds']) == set(ids)

    def call(self, op, **params):
        request = {'op': op, 'nonce': secrets.token_hex(16), **params}
        if self.generation:
            request['serverGeneration'] = self.generation
        if self.id:
            request['leaseId'] = self.id
        self.file.write(json.dumps(request).encode() + b'\n')
        value = json.loads(self.file.readline())
        assert value['nonce'] == request['nonce'] and 'error' not in value, value
        return value

    def close(self):
        self.file.close()
        self.socket.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', required=True)
    parser.add_argument('--app-server-binary', action='store_true')
    args = parser.parse_args()
    binary = pathlib.Path(args.binary).resolve(strict=True)
    root = pathlib.Path(tempfile.mkdtemp(prefix='aa-sel-', dir='/private/tmp'))
    root.chmod(0o700)
    servers = []
    lease = None
    try:
        for name in ['a', 'b']:
            folder = root / name
            folder.mkdir(mode=0o700)
            servers.append(Server(binary, folder, standalone=args.app_server_binary))
        a, b = servers
        selected = a.call('thread/start', {'cwd': str(root)})['thread']['id']
        unrelated = a.call('thread/start', {'cwd': str(root)})['thread']['id']
        independent = b.call('thread/start', {'cwd': str(root)})['thread']['id']
        before = a.call('thread/read', {'threadId': selected, 'includeTurns': False})['thread']['status']
        lease = Lease(a.endpoint, [selected])
        refused = a.call('turn/start', {'threadId': selected, 'input': [{'type': 'text', 'text': 'must not submit'}]}, error=True)
        assert refused['code'] == -32600 and refused['message'] == (
            'Selected conversation is preparing to move; input was not accepted'), refused
        a.call('thread/settings/update', {'threadId': unrelated, 'cwd': str(a.root)})
        b.call('thread/settings/update', {'threadId': independent, 'cwd': str(b.root)})
        assert a.call('thread/read', {'threadId': selected, 'includeTurns': False})['thread']['status'] == before
        assert not lease.call('release')['inputAdmissionPaused']
        lease.close()
        lease = Lease(a.endpoint, [selected])
        lease.close()
        lease = None
        # EOF releases asynchronously; probe a harmless write with bounded retries.
        end = time.monotonic() + 5
        while True:
            try:
                a.call('thread/name/set', {'threadId': selected, 'name': 'released after disconnect'})
                break
            except AssertionError:
                assert time.monotonic() < end
                time.sleep(.02)
        assert all(s.process.poll() is None for s in servers)
        print(json.dumps({'passed': True, 'fixture': str(root), 'submittedTurnWasRefused': True,
                          'checks': ['selected refusal', 'unrelated write', 'independent root write',
                                     'selected read', 'explicit release', 'disconnect release']}))
    finally:
        if lease:
            lease.close()
        for server in reversed(servers):
            server.close()


if __name__ == '__main__':
    main()
