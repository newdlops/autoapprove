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
    parser.add_argument('--retirement', action='store_true')
    parser.add_argument('--case')
    args = parser.parse_args()
    binary = pathlib.Path(args.binary).resolve(strict=True)
    binary_sha256 = hashlib.sha256(binary.read_bytes()).hexdigest()
    spec = importlib.util.spec_from_file_location('selected_fixture', pathlib.Path(__file__).with_name('codex-selected-server-live.py'))
    fixture = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fixture)
    root = pathlib.Path(tempfile.mkdtemp(prefix='aa-selected-shutdown-', dir='/private/tmp'))
    root.chmod(0o700)
    checks = []
    modes = ['retire', 'retire-cohort', 'disconnected-prepare', 'lost-reply', 'external-writer', 'stale-policy', 'replaced-writer', 'archive-collision', 'history-changed'] if args.retirement else ['wrong-phase', 'skipped-revision', 'changed-request', 'connected', 'disconnect']
    if args.case:
        assert args.case in modes, args.case
        modes = [args.case]
    for mode in modes:
        folder = root / mode
        folder.mkdir(mode=0o700)
        server = lease = None
        original = None
        try:
            server = fixture.Server(binary, folder, standalone=True)
            selected = server.call('thread/start', {'cwd': str(folder)})['thread']['id']
            scope = [selected]
            if mode == 'retire-cohort':
                scope.append(server.call('thread/start', {'cwd': str(folder)})['thread']['id'])
            unrelated = server.call('thread/start', {'cwd': str(folder)})['thread']['id']
            server.call('thread/name/set', {'threadId': selected, 'name': 'Preserve selected shutdown'})
            goal = server.call('thread/goal/set', {'threadId': selected, 'objective': 'Keep original Goal instance',
                               'tokenBudget': 4321, 'status': 'paused', 'origin': 'user'})['goal']
            def goal_id():
                with sqlite3.connect((server.home / 'goals_1.sqlite').as_uri() + '?mode=ro', uri=True) as db:
                    return db.execute('SELECT goal_id FROM thread_goals WHERE thread_id=?', (selected,)).fetchone()[0]
            initial_goal_id = goal_id()
            # Seed real stored accounting without submitting a model turn.
            # Zero-only checks would miss lost accounting during shutdown.
            with sqlite3.connect((server.home / 'goals_1.sqlite').as_uri() + '?mode=rw', uri=True) as db:
                assert db.execute('UPDATE thread_goals SET tokens_used=37,time_used_seconds=11 WHERE thread_id=?', (selected,)).rowcount == 1
            goal = server.call('thread/goal/get', {'threadId': selected})['goal']
            assert goal['tokensUsed'] == 37 and goal['timeUsedSeconds'] == 11, goal
            source = server.home
            destination = folder / 'destination-검증'
            destination.mkdir(mode=0o700)
            identity = lambda p: f'{p.stat().st_dev}:{p.stat().st_ino}'
            request_id = str(uuid.uuid4())
            payload = {'formatVersion': 1, 'stage': 'prepared',
                       'request': {'id': request_id, 'source': {'home': str(source), 'physicalHomeID': identity(source)},
                                   'destination': {'home': str(destination), 'physicalHomeID': identity(destination)},
                                   'clients': [{'home': str(source), 'threadIDs': scope}],
                                   'threads': [{'id': tid, 'home': str(source)} for tid in scope]},
                       'currentOwners': {tid: str(source) for tid in scope}}
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
                held = fixture.Lease(server.endpoint, scope)
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
            def observe(witness=None, ids=None):
                with socket.socket(socket.AF_UNIX) as peer:
                    peer.settimeout(5)
                    peer.connect(str(server.endpoint))
                    with peer.makefile('rwb', buffering=0) as stream:
                        nonce = secrets.token_hex(16)
                        stream.write(encoded({'op': 'inspect', 'nonce': nonce}) + b'\n')
                        generation = json.loads(stream.readline())['serverGeneration']
                        request = {'op': 'shutdown-observe' if witness else 'ownership-observe', 'nonce': nonce,
                                   'serverGeneration': generation, 'threadIds': ids or scope}
                        if witness:
                            request['journal'] = witness
                        stream.write(encoded(request) + b'\n')
                        return json.loads(stream.readline())['shutdown' if witness else 'ownership']
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
                    assert all(tid not in loaded for tid in scope) and unrelated in loaded, loaded
                    thread = server.call('thread/read', {'threadId': selected, 'includeTurns': False})['thread']
                    assert thread['name'] == 'Preserve selected shutdown' and '/archived_sessions/' not in thread['path'], thread
                    assert server.call('thread/goal/get', {'threadId': selected})['goal'] == goal
                    assert goal_id() == initial_goal_id
                    server.call('thread/settings/update', {'threadId': unrelated, 'cwd': str(folder)})
                    if args.retirement:
                        assert observe()['ownershipRevision'] == 0
                        payload['execution'] = {'phase': 'retireAttempted', 'ownershipRevision': 99 if mode == 'stale-policy' else 0}
                        stamp = publish(3, stamp['digest'])
                        assert lease.call('journal-sync', journal=stamp)['journalLock']['revision'] == 3
                        writer_path = source / 'thread-writer-locks' / (selected + '.lock')
                        if mode == 'archive-collision':
                            existing = server.call('thread/read', {'threadId': selected, 'includeTurns': False})['thread']['path']
                            collision = source / 'archived_sessions' / pathlib.Path(existing).name
                            collision.parent.mkdir(mode=0o700, exist_ok=True)
                            collision.write_bytes(b'preserve-existing-archive')
                            collision.chmod(0o600)
                            rejected('retire-prepare')
                            assert collision.read_bytes() == b'preserve-existing-archive'
                            assert pathlib.Path(existing).exists(), 'Failed preparation moved the original history'
                        elif mode == 'external-writer':
                            writer = os.open(writer_path, os.O_RDWR | os.O_CREAT, 0o600)
                            try:
                                fcntl.flock(writer, fcntl.LOCK_EX | fcntl.LOCK_NB)
                                rejected('retire-prepare')
                            finally:
                                os.close(writer)
                        elif mode == 'stale-policy':
                            rejected('retire-prepare')
                        else:
                            proof = lease.call('retire-prepare')['retirement']
                            assert proof['phase'] == 'writers-held' and proof['writersStopped'], proof
                            assert proof['threadIds'] == sorted(scope) and not proof['membershipComplete'] and not proof['migrationAuthorized'], proof
                            files = proof['files']
                            assert set(row['threadId'] for row in files) == set(scope) and len(set(row['relativePath'] for row in files)) == len(files), files
                            for row in files:
                                path = source / row['relativePath']
                                assert row['relativePath'].startswith('archived_sessions/') and path.resolve().is_relative_to(source.resolve()), row
                                info = path.stat()
                                assert hashlib.sha256(path.read_bytes()).hexdigest() == row['sha256'], row
                                assert info.st_size == row['size'] and identity(path) == row['fileIdentity'], row
                                assert info.st_mtime_ns == row['modifiedSeconds'] * 1_000_000_000 + row['modifiedNanoseconds'], row
                            thread = server.call('thread/read', {'threadId': selected, 'includeTurns': False})['thread']
                            assert '/archived_sessions/' in thread['path'], thread
                            assert not (source / '.autoapprove-ownership').exists()
                            probe = os.open(writer_path, os.O_RDWR)
                            try:
                                try:
                                    fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
                                    raise AssertionError('Native preparation did not retain the actual writer lock')
                                except BlockingIOError:
                                    pass
                                for tid in scope:
                                    if tid == selected:
                                        continue
                                    second = os.open(source / 'thread-writer-locks' / (tid + '.lock'), os.O_RDWR)
                                    try:
                                        try:
                                            fcntl.flock(second, fcntl.LOCK_EX | fcntl.LOCK_NB)
                                            raise AssertionError('A selected cohort writer lock was not held')
                                        except BlockingIOError:
                                            pass
                                    finally:
                                        os.close(second)
                                if mode == 'history-changed':
                                    changed = source / files[0]['relativePath']
                                    with changed.open('ab') as output:
                                        output.write(b'\n')
                                    rejected('retire-commit')
                                    lease.close()
                                    lease = None
                                elif mode == 'replaced-writer':
                                    os.rename(writer_path, writer_path.with_suffix('.original'))
                                    fd = os.open(writer_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                                    with os.fdopen(fd, 'wb') as output:
                                        output.write(b'preserve-replaced-entry')
                                    rejected('retire-commit')
                                    lease.close()
                                    lease = None
                                elif mode == 'disconnected-prepare':
                                    lease.close()
                                    lease = None
                                else:
                                    if mode == 'lost-reply':
                                        lease.file.write(encoded({'op': 'retire-commit', 'nonce': secrets.token_hex(16),
                                                                  'serverGeneration': lease.generation, 'leaseId': lease.id}) + b'\n')
                                    else:
                                        receipt = lease.call('retire-commit')['retirement']
                                        assert receipt['phase'] == 'retired' and receipt['ownershipRevision'] == 1, receipt
                                        assert receipt['homeIdentity'] == identity(source) and receipt['writersStopped'] and receipt['files'] == files, receipt
                                    end = time.monotonic() + 10
                                    while True:
                                        owned = observe()
                                        if owned['ownershipRevision'] == 1:
                                            break
                                        assert time.monotonic() < end, owned
                                        time.sleep(.02)
                                    assert owned['observationOnly'] and not owned['migrationAuthorized'], owned
                                    assert owned['threads'] == [{'threadId': tid, 'requestId': request_id,
                                            'ownerHomeIdentity': identity(destination), 'phase': 'retired'} for tid in sorted(scope)], owned
                                    before = (source / '.autoapprove-ownership/state.json').read_bytes()
                                    if mode == 'retire':
                                        rejected('retire-commit')
                                    lease.close()
                                    lease = None
                                    assert observe() == owned
                                    assert (source / '.autoapprove-ownership/state.json').read_bytes() == before
                                end = time.monotonic() + 5
                                while True:
                                    try:
                                        fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
                                        break
                                    except BlockingIOError:
                                        assert time.monotonic() < end, 'Disconnected native writer guard leaked'
                                        time.sleep(.02)
                            finally:
                                os.close(probe)
                            if mode == 'replaced-writer':
                                assert writer_path.read_bytes() == b'preserve-replaced-entry', 'Native cleanup removed a replaced lock entry'
                        if mode in ['disconnected-prepare', 'external-writer', 'stale-policy', 'replaced-writer', 'archive-collision', 'history-changed']:
                            assert not (source / '.autoapprove-ownership').exists()
                    else:
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
            if mode in ['connected', 'disconnect', 'disconnected-prepare', 'external-writer', 'stale-policy', 'replaced-writer', 'archive-collision', 'history-changed']:
                current = server.call('thread/read', {'threadId': selected, 'includeTurns': False})['thread']
                if '/archived_sessions/' in current['path']:
                    server.call('thread/unarchive', {'threadId': selected})
                resumed = server.call('thread/resume', {'threadId': selected})['thread']
                assert resumed['id'] == selected and goal_id() == initial_goal_id
                assert server.call('thread/goal/get', {'threadId': selected})['goal'] == goal
            if mode in ['retire', 'retire-cohort', 'lost-reply']:
                denied = server.call('thread/resume', {'threadId': selected}, error=True)
                assert 'another login group' in denied['message'], denied
                # The public Goal API excludes archived sessions. The native
                # read-only cohort observes their actual stored Goal directly.
                lease = fixture.Lease(server.endpoint, scope)
                archived = lease.call('cohort')['runtimeCohort']
                archived_row = next(row for row in archived['threads'] if row['threadId'] == selected)
                assert archived_row['goal'] == goal and archived_row['goalId'] == initial_goal_id, archived_row
                lease.call('release')
                lease.close()
                lease = None
                assert goal_id() == initial_goal_id
            else:
                assert not (source / '.autoapprove-ownership').exists()
            checks.append(mode)
        finally:
            if lease:
                lease.close()
            if original is not None:
                os.close(original)
            if server:
                server.close()
    assert hashlib.sha256(binary.read_bytes()).hexdigest() == binary_sha256, 'Binary changed during fixture execution'
    report = {'passed': True, 'fixture': str(root), 'binarySHA256': binary_sha256, 'checks': checks, 'modelTurnsSubmitted': 0,
              'policyWrites': sum(case in ['retire', 'retire-cohort', 'lost-reply'] for case in checks), 'retirementVerified': args.retirement and {'retire', 'retire-cohort', 'lost-reply'}.issubset(checks), 'migrationVerified': False}
    (root / 'report.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report))


if __name__ == '__main__':
    main()
