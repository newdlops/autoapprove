#!/usr/bin/env python3
"""Owned journal-lock IPC only; no migration, credentials, or model turns."""
import argparse
import array
import base64
import fcntl
import hashlib
import importlib.util
import json
import os
import pathlib
import socket
import tempfile
import uuid


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', required=True)
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location('selected_fixture', pathlib.Path(__file__).with_name('codex-selected-server-live.py'))
    fixture = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fixture)
    root = pathlib.Path(tempfile.mkdtemp(prefix='aa-journal-fd-', dir='/private/tmp'))
    root.chmod(0o700)
    checks = []
    for mode in ['valid', 'wrong-home', 'independent-open', 'wrong-tag', 'two-descriptors', 'wrong-digest', 'wrong-scope']:
        folder = root / mode
        folder.mkdir(mode=0o700)
        server = lease = None
        opened = []
        try:
            server = fixture.Server(pathlib.Path(args.binary).resolve(strict=True), folder, standalone=True)
            tid = server.call('thread/start', {'cwd': str(folder)})['thread']['id']
            source = server.home
            destination = folder / 'destination-검증'
            destination.mkdir(mode=0o700)
            identity = lambda p: f'{p.stat().st_dev}:{p.stat().st_ino}'
            request_id = str(uuid.uuid4())
            row_id = str(uuid.uuid4()) if mode == 'wrong-scope' else tid
            payload = {'formatVersion': 1, 'stage': 'prepared',
                       'request': {'id': request_id, 'source': {'home': str(source), 'physicalHomeID': identity(source)},
                                   'destination': {'home': str(destination), 'physicalHomeID': identity(destination)},
                                   'clients': [{'home': str(source), 'threadIDs': [row_id]}],
                                   'threads': [{'id': row_id, 'home': str(source)}]},
                       'currentOwners': {row_id: str(source)}}
            body = {'formatVersion': 1, 'id': request_id, 'revision': 1,
                    'homes': sorted([{'path': str(p), 'identity': identity(p)} for p in [source, destination]], key=lambda p: p['path']),
                    'payload': base64.b64encode(encoded(payload)).decode(), 'terminal': False}
            digest = hashlib.sha256(encoded(body)).hexdigest()
            record = {**body, 'digest': digest}
            for home in [source, destination]:
                directory = home / '.autoapprove-migrations'
                directory.mkdir(mode=0o700, exist_ok=True)
                for name in ['active.json', request_id + '.json']:
                    fd = os.open(directory / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                    with os.fdopen(fd, 'wb') as output:
                        output.write(encoded(record))
            original = os.open(source / '.autoapprove-migrations/lock', os.O_RDWR)
            opened.append(original)
            fcntl.flock(original, fcntl.LOCK_EX | fcntl.LOCK_NB)
            passed = original
            if mode in ['wrong-home', 'independent-open']:
                path = (destination if mode == 'wrong-home' else source) / '.autoapprove-migrations/lock'
                passed = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
                opened.append(passed)
            lease = fixture.Lease(server.endpoint, [tid])
            ready = lease.call('journal-lock', journal={'requestId': request_id, 'revision': 1,
                               'digest': ('0' * 64 if mode == 'wrong-digest' else digest)})
            assert ready['journalDescriptorReady'] and not ready['migrationAuthorized'], ready
            packet = array.array('i', [passed, passed] if mode == 'two-descriptors' else [passed])
            assert lease.socket.sendmsg([b'X' if mode == 'wrong-tag' else b'F'],
                                        [(socket.SOL_SOCKET, socket.SCM_RIGHTS, packet)]) == 1
            line = lease.file.readline()
            if mode == 'valid':
                held = json.loads(line)
                assert held['nonce'] == ready['nonce'] and not held['migrationAuthorized'], held
                witness = held['journalLock']
                assert witness['phase'] == 'held' and witness['role'] == 'source' and witness['homeIdentity'] == identity(source), witness
                assert witness['requestId'] == request_id and witness['digest'] == digest and not witness['migrationAuthorized'], witness
                os.close(original)
                opened.remove(original)
                probe = os.open(source / '.autoapprove-migrations/lock', os.O_RDWR)
                opened.append(probe)
                try:
                    fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    raise AssertionError('Native copy did not retain kernel lock')
                except BlockingIOError:
                    pass
                lease.call('release')
                fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
            else:
                assert not line, (mode, line)
                # Rejection must close all received copies rather than leaking
                # a lock that survives after its original sender closes.
                for fd in opened:
                    os.close(fd)
                opened.clear()
                probe = os.open(source / '.autoapprove-migrations/lock', os.O_RDWR)
                opened.append(probe)
                fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
            assert not (source / '.autoapprove-ownership').exists()
            checks.append(mode)
        finally:
            if lease:
                lease.close()
            for fd in opened:
                os.close(fd)
            if server:
                server.close()
    report = {'passed': True, 'fixture': str(root), 'checks': checks, 'modelTurnsSubmitted': 0,
              'policyWrites': 0, 'migrationVerified': False}
    (root / 'report.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report))


if __name__ == '__main__':
    main()
