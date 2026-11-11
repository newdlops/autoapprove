#!/usr/bin/env python3
"""Exercise archive shutdown against an owned server, never a production home."""
import argparse
import importlib.util
import json
import pathlib
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', required=True)
    parser.add_argument('--app-server-binary', action='store_true')
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location(
        'selected_fixture', pathlib.Path(__file__).with_name('codex-selected-server-live.py'))
    fixture = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fixture)
    root = pathlib.Path(tempfile.mkdtemp(prefix='aa-retire-live-', dir='/private/tmp'))
    root.chmod(0o700)
    server = None
    try:
        server = fixture.Server(pathlib.Path(args.binary).resolve(strict=True), root,
                                standalone=args.app_server_binary)
        call = server.call
        selected = call('thread/start', {'cwd': str(root)})['thread']['id']
        unrelated = call('thread/start', {'cwd': str(root)})['thread']['id']
        call('thread/name/set', {'threadId': selected, 'name': 'Owned shutdown preservation'})
        goal = call('thread/goal/set', {
            'threadId': selected, 'objective': 'Preserve this paused Goal',
            'tokenBudget': 1234, 'status': 'paused', 'origin': 'user'})['goal']
        call('thread/archive', {'threadId': selected})
        loaded = call('thread/loaded/list', {})['data']
        assert selected not in loaded and unrelated in loaded, loaded
        archived = call('thread/read', {'threadId': selected, 'includeTurns': False})['thread']
        assert archived['name'] == 'Owned shutdown preservation', archived
        call('thread/unarchive', {'threadId': selected})
        resumed = call('thread/resume', {'threadId': selected})['thread']
        assert resumed['id'] == selected
        assert call('thread/goal/get', {'threadId': selected})['goal'] == goal
        call('thread/name/set', {'threadId': unrelated, 'name': 'Independent runtime remains writable'})
        # Exercise capture/removal again after a fresh runtime replaces the old
        # instance under the same persisted thread identity.
        call('thread/archive', {'threadId': selected})
        loaded = call('thread/loaded/list', {})['data']
        assert selected not in loaded and unrelated in loaded, loaded
        report = {'passed': True, 'fixture': str(root), 'modelTurnsSubmitted': 0,
                  'checks': ['confirmed shutdown removes captured runtime',
                             'archive preserves name and paused Goal',
                             'unarchive and resume preserve thread identity and Goal',
                             'replacement runtime archives successfully',
                             'unrelated runtime remains loaded and writable'],
                  'migrationVerified': False}
        (root / 'report.json').write_text(json.dumps(report, indent=2))
        print(json.dumps(report))
    finally:
        if server:
            server.close()


if __name__ == '__main__':
    main()
