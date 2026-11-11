#!/usr/bin/env python3
"""Actual active turn + queue + paused Goal under selected admission.
Uses a heartbeat-only loopback provider and private server homes.
"""
import argparse
import importlib.util
import json
import pathlib
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

spec = importlib.util.spec_from_file_location('selected_fixture', str(pathlib.Path(__file__).with_name('codex-selected-server-live.py')))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
requests = []
stop = threading.Event()
finish_first = threading.Event()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        data = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append(data)
        number = len(requests)
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        try:
            self.wfile.write(b'data: {"type":"response.created","response":{"id":"owned-held","status":"in_progress","output":[]}}\n\n')
            self.wfile.flush()
            while not stop.wait(.1):
                if number == 1 and finish_first.is_set():
                    item = {'id': 'owned-finished', 'type': 'message', 'role': 'assistant',
                            'status': 'completed', 'content': [{'type': 'output_text', 'text': 'Owned turn complete.'}]}
                    events = [{'type': 'response.output_item.added', 'output_index': 0, 'item': item},
                              {'type': 'response.output_item.done', 'output_index': 0, 'item': item},
                              {'type': 'response.completed', 'response': {'id': 'owned-held', 'status': 'completed',
                               'output': [item], 'usage': {'input_tokens': 1, 'output_tokens': 1, 'total_tokens': 2}}}]
                    for event in events:
                        self.wfile.write(('data: ' + json.dumps(event) + '\n\n').encode())
                    self.wfile.flush()
                    return
                self.wfile.write(b': owned heartbeat\n\n')
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


def until(test, label, timeout=15):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if test():
            return
        time.sleep(.05)
    raise AssertionError('Timed out: ' + label)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', required=True)
    parser.add_argument('--app-server-binary', action='store_true')
    args = parser.parse_args()
    api = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    worker = threading.Thread(target=api.serve_forever, daemon=True)
    worker.start()
    root = pathlib.Path(tempfile.mkdtemp(prefix='aa-queue-', dir='/private/tmp'))
    root.chmod(0o700)
    config = f'''model="fixture-model"
model_provider="fixture"
approval_policy="never"
sandbox_mode="read-only"
check_for_update_on_startup=false
cli_auth_credentials_store="file"
[model_providers.fixture]
name="Fixture"
base_url="http://127.0.0.1:{api.server_port}/v1"
wire_api="responses"
requires_openai_auth=false
[features]
goals=true
[analytics]
enabled=false
'''
    server = lease = None
    try:
        server = fixture.Server(pathlib.Path(args.binary).resolve(strict=True), root, config,
                                standalone=args.app_server_binary)
        call = server.call
        tid = call('thread/start', {'cwd': str(root)})['thread']['id']
        goal = call('thread/goal/set', {'threadId': tid, 'objective': 'Owned queue preservation',
                                      'tokenBudget': 1234, 'status': 'paused', 'origin': 'user'})['goal']
        turn = call('turn/start', {'threadId': tid, 'input': [{'type': 'text', 'text': 'OWNED_HELD_TURN'}]})['turn']
        until(lambda: len(requests) == 1, 'held model request')
        queued = call('thread/queue/add', {'threadId': tid, 'input': [{'type': 'text', 'text': 'OWNED_QUEUED_INPUT'}],
                                          'clientUserMessageId': 'owned-queued-id'})['queuedSubmission']
        lease = fixture.Lease(server.endpoint, [tid])
        denied = call('thread/queue/start', {'threadId': tid, 'queuedSubmissionId': queued['id']}, error=True)
        assert denied['code'] == -32600 and 'input was not accepted' in denied['message'], denied
        finish_first.set()
        until(lambda: call('thread/read', {'threadId': tid, 'includeTurns': False})['thread']['status']['type'] == 'idle', 'normally completed idle')
        # Wait across the native automatic dispatch interval, renewing ownership.
        for _ in range(12):
            lease.call('renew')
            assert call('thread/queue/list', {'threadId': tid})['data'] == [queued]
            assert len(requests) == 1, 'Queued input or paused Goal ran while held'
            time.sleep(1)
        resting = call('thread/goal/get', {'threadId': tid})['goal']
        assert resting['status'] == 'paused' and resting['tokenBudget'] == goal['tokenBudget']
        assert resting['objective'] == goal['objective']
        lease.call('release')
        lease.close()
        lease = None
        until(lambda: len(requests) >= 2, 'automatic queued input after release', timeout=20)
        assert len(requests) == 2
        assert 'OWNED_QUEUED_INPUT' in json.dumps(requests[1]['input'])
        assert call('thread/queue/list', {'threadId': tid})['data'] == []
        assert call('thread/goal/get', {'threadId': tid})['goal']['status'] == 'paused'
        print(json.dumps({'passed': True, 'fixture': str(root), 'queuedItemRetainedDuringHold': True,
                          'automaticDispatchAfterRelease': True, 'noDuplicateSubmission': True,
                          'pausedGoalPreserved': True, 'providerRequests': len(requests)}))
    finally:
        if lease:
            lease.close()
        if server:
            server.close()
        stop.set()
        api.shutdown()
        api.server_close()


if __name__ == '__main__':
    main()
