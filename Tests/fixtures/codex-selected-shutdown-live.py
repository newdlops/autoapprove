#!/usr/bin/env python3
"""Owned native shutdown IPC; no migration, credentials, or model turns."""
import argparse
import array
import base64
import fcntl
import hashlib
import importlib.util
import json
import os
import pathlib
import secrets
import socket
import sqlite3
import tempfile
import time
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
    root = pathlib.Path(tempfile.mkdtemp(prefix='aa-selected-shutdown-', dir='/private/tmp'))
    root.chmod(0o700)
    checks = []
    for mode in ['wrong-phase', 'skipped-revision', 'changed-request', 'connected', 'disconnect']:
        folder = root / mode
        folder.mkdir(mode=0o700)
        server = lease = None
        original = None
        try:
            server = fixture.Server(pathlib.Path(args.binary).resolve(strict=True), folder, standalone=True)
            selected = server.call('thread/start', {'cwd': str(folder)})['thread']['id']
            unrelated = server.call('thread/start', {'cwd': str(folder)})['thread']['id']
            server.call('thread/name/set', {'threadId': selected, 'name': 'Preserve selected shutdown'})
            goal = server.call('thread/goal/set', {'threadId': selected, 'objective': 'Keep original Goal instance',
                               'tokenBudget': 4321, 'status': 'paused', 'origin': 'user'})['goal']
            def goal_id():
                with sqlite3.connect((server.home / 'goals_1.sqlite').as_uri() + '?mode=ro', uri=True) as db:
                    return db.execute('SELECT goal_id FROM thread_goals WHERE thread_id=?', (selected,)).fetchone()[0]
            initial_goal_id = goal_id()
            source = server.home
            destination = folder / 'destination-검증'
            destination.mkdir(mode=0o700)
            identity = lambda p: f'{p.stat().st_dev}:{p.stat().st_ino}'
            request_id = str(uuid.uuid4())
            payload = {'formatVersion': 1, 'stage': 'prepared',
                       'request': {'id': request_id, 'source': {'home': str(source), 'physicalHomeID': identity(source)},
                                   'destination': {'home': str(destination), 'physicalHomeID': identity(destination)},
                                   'clients': [{'home': str(source), 'threadIDs': [selected]}],
                                   'threads': [{'id': selected, 'home': str(source)}]},
                       'currentOwners': {selected: str(source)}}
            def publish(revision, previous=None):
                body = {'formatVersion': 1, 'id': request_id, 'revision': revision,
                        'homes': sorted([{'path': str(p), 'identity': identity(p)} for p in [source, destination]], key=lambda p: p['path']),
                        'payload': base64.b64encode(encoded(payload)).decode(), 'terminal': False}
                if previous:
                    body['previousDigest'] = previous
                digest = hashlib.sha256(encoded(body)).hexdigest()
                record = {**body, 'digest': digest}
                for home in [source, destination]:
                    directory = home / '.autoapprove-migrations'
                    directory.mkdir(mode=0o700, exist_ok=True)
                    for name in ['active.json', request_id + '.json']:
                        temp = directory / (name + '.tmp')
                        fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                        with os.fdopen(fd, 'wb') as output:
                            output.write(encoded(record))
                            output.flush()
                            os.fsync(output.fileno())
                        os.replace(temp, directory / name)
                return {'requestId': request_id, 'revision': revision, 'digest': digest}
            stamp = publish(1)
            original = os.open(source / '.autoapprove-migrations/lock', os.O_RDWR)
            fcntl.flock(original, fcntl.LOCK_EX | fcntl.LOCK_NB)
            def borrow():
                held = fixture.Lease(server.endpoint, [selected])
                assert held.call('journal-lock', journal=stamp)['journalDescriptorReady']
                held.socket.sendmsg([b'F'], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array('i', [original]))])
                assert json.loads(held.file.readline())['journalLock']['digest'] == stamp['digest']
                return held
            def rejected(operation, **params):
                try:
                    lease.call(operation, **params)
                except (json.JSONDecodeError, BrokenPipeError, ConnectionResetError):
                    return
                raise AssertionError(operation + ' unexpectedly accepted')
            def observe(witness, ids=None):
                with socket.socket(socket.AF_UNIX) as peer:
                    peer.settimeout(5)
                    peer.connect(str(server.endpoint))
                    with peer.makefile('rwb', buffering=0) as stream:
                        nonce = secrets.token_hex(16)
                        stream.write(encoded({'op': 'inspect', 'nonce': nonce}) + b'\n')
                        generation = json.loads(stream.readline())['serverGeneration']
                        stream.write(encoded({'op': 'shutdown-observe', 'nonce': nonce, 'serverGeneration': generation,
                                              'threadIds': ids or [selected], 'journal': witness}) + b'\n')
                        return json.loads(stream.readline())['shutdown']
            lease = borrow()
            if mode == 'wrong-phase':
                rejected('shutdown-begin')
            else:
                payload['execution'] = {'phase': 'shutdownAttempted'}
                if mode == 'changed-request':
                    payload['request']['clients'][0]['unexpectedChange'] = True
                previous = stamp['digest']
                stamp = publish(3 if mode == 'skipped-revision' else 2, previous)
                if mode in ['skipped-revision', 'changed-request']:
                    rejected('journal-sync', journal=stamp)
                else:
                    assert lease.call('journal-sync', journal=stamp)['journalLock']['revision'] == 2
                    status = lease.call('shutdown-begin')['shutdown']
                    if mode == 'disconnect':
                        lease.close()
                        lease = None
                    end = time.monotonic() + 15
                    while status['state'] == 'pending':
                        assert time.monotonic() < end, status
                        time.sleep(.02)
                        status = observe(stamp) if lease is None else lease.call('shutdown-status')['shutdown']
                    assert status['state'] == 'stopped' and status['runtimesStopped'], status
                    assert status['observationOnly'] and not status['writersStopped'] and not status['migrationAuthorized'], status
                    assert observe(stamp) == status
                    try:
                        observe({**stamp, 'digest': '0' * 64})
                        raise AssertionError('Wrong journal witness observed shutdown')
                    except json.JSONDecodeError:
                        pass
                    try:
                        observe(stamp, [unrelated])
                        raise AssertionError('Wrong scope observed shutdown')
                    except json.JSONDecodeError:
                        pass
                    loaded = server.call('thread/loaded/list', {})['data']
                    assert selected not in loaded and unrelated in loaded, loaded
                    thread = server.call('thread/read', {'threadId': selected, 'includeTurns': False})['thread']
                    assert thread['name'] == 'Preserve selected shutdown' and '/archived_sessions/' not in thread['path'], thread
                    assert server.call('thread/goal/get', {'threadId': selected})['goal'] == goal
                    assert goal_id() == initial_goal_id
                    server.call('thread/settings/update', {'threadId': unrelated, 'cwd': str(folder)})
                    if lease:
                        assert not lease.call('release')['inputAdmissionPaused']
                        lease.close()
                    lease = borrow()
                    rejected('shutdown-begin')
            if mode in ['wrong-phase', 'skipped-revision', 'changed-request']:
                assert selected in server.call('thread/loaded/list', {})['data']
            if lease:
                lease.close()
                lease = None
            os.close(original)
            original = None
            if mode in ['connected', 'disconnect']:
                resumed = server.call('thread/resume', {'threadId': selected})['thread']
                assert resumed['id'] == selected and goal_id() == initial_goal_id
                assert server.call('thread/goal/get', {'threadId': selected})['goal'] == goal
            assert not (source / '.autoapprove-ownership').exists()
            checks.append(mode)
        finally:
            if lease:
                lease.close()
            if original is not None:
                os.close(original)
            if server:
                server.close()
    report = {'passed': True, 'fixture': str(root), 'checks': checks, 'modelTurnsSubmitted': 0,
              'policyWrites': 0, 'migrationVerified': False}
    (root / 'report.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report))


if __name__ == '__main__':
    main()
