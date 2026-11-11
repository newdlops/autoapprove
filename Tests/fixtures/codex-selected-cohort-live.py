#!/usr/bin/env python3
"""Read the actual selected runtime cohort; no model turns or production homes."""
import argparse
import importlib.util
import json
import pathlib
import sqlite3
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
    root = pathlib.Path(tempfile.mkdtemp(prefix='aa-cohort-live-', dir='/private/tmp'))
    root.chmod(0o700)
    server = lease = None
    try:
        server = fixture.Server(pathlib.Path(args.binary).resolve(strict=True), root, standalone=True)
        call = server.call
        selected = call('thread/start', {'cwd': str(root)})['thread']['id']
        unrelated = call('thread/start', {'cwd': str(root)})['thread']['id']
        goal = call('thread/goal/set', {
            'threadId': selected, 'objective': 'Native cohort identity preservation',
            'tokenBudget': 4321, 'status': 'paused', 'origin': 'user'})['goal']
        database = sqlite3.connect((server.home / 'goals_1.sqlite').as_uri() + '?mode=ro', uri=True)
        try:
            goal_id = database.execute('SELECT goal_id FROM thread_goals WHERE thread_id=?', (selected,)).fetchone()[0]
        finally:
            database.close()
        lease = fixture.Lease(server.endpoint, [selected])
        first = lease.call('cohort')['runtimeCohort']
        assert first['schemaVersion'] == 1 and first['producer'] == 'autoapprove-selected-runtime-cohort', first
        assert first['inputScopeVerified'] and first['knownSubtreeCovered'] and first['readyForWriterShutdown'], first
        assert not first['membershipComplete'] and not first['writersStopped'] and not first['migrationAuthorized'], first
        assert first['missingThreadIds'] == [] and len(first['threads']) == 1, first
        row = first['threads'][0]
        assert row['threadId'] == selected and row['loaded'] and row['persistent'], row
        assert row['goalId'] == goal_id and row['goal'] == goal, row
        assert all(not row[key] for key in ['hasActiveTurn', 'hasBackgroundTerminal', 'hasProtectedRequest', 'hasQueuedInput']), row
        assert lease.call('cohort')['runtimeCohort'] == first
        call('thread/settings/update', {'threadId': unrelated, 'cwd': str(root)})
        assert lease.call('cohort')['runtimeCohort'] == first
        call('thread/name/set', {'threadId': selected, 'name': 'MUST_NOT_BE_APPLIED'}, error=True)
        assert call('thread/goal/get', {'threadId': selected})['goal'] == goal
        lease.call('release')
        lease.close()
        lease = None
        # Archived descendants are part of a move's native scope too. Reading
        # their Goal/queue must not unarchive or cold-load them as a side effect.
        call('thread/archive', {'threadId': selected})
        lease = fixture.Lease(server.endpoint, [selected])
        cold = lease.call('cohort')['runtimeCohort']
        row = cold['threads'][0]
        assert cold['readyForWriterShutdown'] and not row['loaded'] and row['status'] == 'not-loaded', cold
        assert row['goalId'] == goal_id and row['goal'] == goal, row
        assert selected not in call('thread/loaded/list', {})['data']
        path = call('thread/read', {'threadId': selected, 'includeTurns': False})['thread']['path']
        assert '/archived_sessions/' in path, path
        lease.call('release')
        lease.close()
        lease = None
        # An invented selected ID must not become an empty "ready" cohort.
        lease = fixture.Lease(server.endpoint, [str(uuid.uuid4())])
        try:
            lease.call('cohort')
            raise AssertionError('Invented ID was attested')
        except (json.JSONDecodeError, BrokenPipeError, ConnectionResetError):
            pass
        lease.close()
        lease = None
        report = {'passed': True, 'fixture': str(root), 'modelTurnsSubmitted': 0,
                  'checks': ['exact selected native scope', 'actual stored Goal UUID and counters',
                             'stable read-only cohort', 'unrelated runtime remains writable',
                             'selected writes remain blocked', 'archived cold Goal and queue read without restore',
                             'invented ID cannot be attested'],
                  'completeClientCensusVerified': False, 'migrationVerified': False}
        (root / 'report.json').write_text(json.dumps(report, indent=2))
        print(json.dumps(report))
    finally:
        if lease:
            lease.close()
        if server:
            server.close()


if __name__ == '__main__':
    main()
