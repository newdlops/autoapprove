#!/usr/bin/env python3
"""Actual managed server policy hooks; fixture-owned homes and no inference.

Policy files are installed by this fixture, not by production migration IPC.
This verifies runtime enforcement, never migration authority or full census.
"""
import argparse
import importlib.util
import json
import os
import pathlib
import tempfile
import uuid


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', required=True)
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location(
        'selected_fixture', pathlib.Path(__file__).with_name('codex-selected-server-live.py'))
    fixture = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fixture)
    root = pathlib.Path(tempfile.mkdtemp(prefix='aa-policy-live-', dir='/private/tmp'))
    root.chmod(0o700)
    server = None
    try:
        server = fixture.Server(pathlib.Path(args.binary).resolve(strict=True), root, standalone=True)
        call = server.call
        cold = call('thread/start', {'cwd': str(root)})['thread']['id']
        retired = call('thread/start', {'cwd': str(root)})['thread']['id']
        unrelated = call('thread/start', {'cwd': str(root)})['thread']['id']
        goal = call('thread/goal/set', {
            'threadId': cold, 'objective': 'Preserve identity behind ownership fence',
            'tokenBudget': 4321, 'status': 'paused', 'origin': 'user'})['goal']
        call('thread/archive', {'threadId': cold})
        call('thread/unarchive', {'threadId': cold})
        rollout = call('thread/read', {'threadId': cold, 'includeTurns': False})['thread']['path']
        info = server.home.stat()
        identity = f'{info.st_dev}:{info.st_ino}'
        policy = server.home / '.autoapprove-ownership'
        policy.mkdir(mode=0o700)
        request = str(uuid.uuid4())

        def write(name, value):
            temporary = policy / ('.fixture-' + uuid.uuid4().hex)
            fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, 'w') as output:
                json.dump(value, output)
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, policy / name)

        write('required.json', {'schemaVersion': 1, 'homeIdentity': identity})
        state = {'schemaVersion': 1, 'homeIdentity': identity, 'revision': 1, 'threads': [
            {'threadId': cold, 'requestId': request, 'ownerHomeIdentity': identity, 'phase': 'incoming'},
            {'threadId': retired, 'requestId': request, 'ownerHomeIdentity': '1:2', 'phase': 'retired'}]}
        write('state.json', state)
        # Path-based resume has no trusted thread ID in its RPC scope. Core
        # must check the actual ID found in the rollout before spawning it.
        resumed_by_path = {'threadId': str(uuid.uuid4()), 'path': rollout}
        refused = call('thread/resume', resumed_by_path, error=True)
        expected_denial = 'Conversation is moving or belongs to another login group; reconnect through AutoApprove'
        assert refused['message'] == expected_denial, refused
        refused = call('turn/start', {'threadId': retired, 'input': [
            {'type': 'text', 'text': 'MUST_NOT_REACH_MODEL'}]}, error=True)
        assert refused['message'] == expected_denial, refused
        assert call('thread/read', {'threadId': retired, 'includeTurns': False})['thread']['id'] == retired
        call('thread/name/set', {'threadId': unrelated, 'name': 'Unrelated writer remains available'})
        assert cold not in call('thread/loaded/list', {})['data']
        state['revision'] = 2
        state['threads'][0]['phase'] = 'active'
        write('state.json', state)
        assert call('thread/resume', resumed_by_path)['thread']['id'] == cold
        assert call('thread/goal/get', {'threadId': cold})['goal'] == goal
        # An installed but damaged policy cannot revert to the legacy behavior.
        write('state.json', {'schemaVersion': 1})
        call('thread/name/set', {'threadId': unrelated, 'name': 'MUST_NOT_BE_APPLIED'}, error=True)
        assert call('thread/read', {'threadId': unrelated, 'includeTurns': False})['thread']['name'] == 'Unrelated writer remains available'
        report = {'passed': True, 'fixture': str(root), 'modelTurnsAccepted': 0,
                  'checks': ['Core path resume rejects incoming owner',
                             'live retired runtime rejects new input',
                             'read-only observation remains available',
                             'unrelated writes remain available with valid policy',
                             'activation permits exact UUID and paused Goal restoration',
                             'damaged installed policy fails closed'],
                  'productionPolicyIPCVerified': False, 'migrationVerified': False}
        (root / 'report.json').write_text(json.dumps(report, indent=2))
        print(json.dumps(report))
    finally:
        if server:
            server.close()


if __name__ == '__main__':
    main()
