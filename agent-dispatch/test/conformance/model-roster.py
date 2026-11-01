#!/usr/bin/env python3
"""Read Codex configuration and model/list through stdio JSON-RPC; never start a turn."""
import json
import subprocess
import sys


def check(command):
    process = subprocess.Popen(command + ['app-server'], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                               text=True)
    try:
        def request(number, method, params):
            process.stdin.write(json.dumps(dict(id=number, method=method, params=params)) + '\n')
            process.stdin.flush()
            for line in process.stdout:
                message = json.loads(line)
                if message.get('id') == number:
                    if 'error' in message:
                        raise ValueError('model metadata request failed')
                    return message['result']
            raise ValueError('model metadata stream ended')

        request(1, 'initialize', {'clientInfo': {'name': 'dispatch-smoke', 'version': '1'}})
        process.stdin.write('{"method":"initialized","params":{}}\n')
        process.stdin.flush()
        config = request(2, 'config/read', {'includeLayers': False})['config']
        configured = config.get('model')
        models = []
        cursor = None
        number = 3
        while True:
            result = request(number, 'model/list', {'cursor': cursor, 'limit': 100})
            models.extend(result['data'])
            cursor = result.get('nextCursor')
            if not cursor:
                break
            number += 1
        selected = configured or next((m['model'] for m in models if m.get('isDefault')), None)
        if not selected or not any(m['model'] == selected for m in models):
            raise ValueError('configured default model absent from roster')
        print('PASS codex-models: configured default offered')
    finally:
        # This metadata-only child belongs to this probe.
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


if __name__ == '__main__':
    try:
        check(sys.argv[1:] or ['codex'])
    except (ValueError, KeyError, OSError) as error:
        print('FAIL codex-models: ' + str(error), file=sys.stderr)
        sys.exit(1)
