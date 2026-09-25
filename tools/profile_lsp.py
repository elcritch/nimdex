#!/usr/bin/env python3
"""Exercise a real daemon with unique revisions; print RSS and latency as JSONL.

Example: python3 tools/profile_lsp.py --server /tmp/nimdex --cycles 50
Use --saved with an older server to measure a comparable saved-file baseline.
The fixture, compiler cache and stderr log live in a temporary directory.
"""
import argparse
import json
import os
from pathlib import Path
import select
import subprocess
import tempfile
import threading
import time


class Client:
    def __init__(self, server, root, log):
        self.process = subprocess.Popen([str(server), 'daemon'], cwd=root,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log)
        self.buffer = bytearray()
        self.ident = 0
        self.diagnostics = {}

    def send(self, method, params, ident=None):
        message = {'jsonrpc': '2.0', 'method': method, 'params': params}
        if ident is not None:
            message['id'] = ident
        data = json.dumps(message).encode()
        self.process.stdin.write(f'Content-Length: {len(data)}\r\n\r\n'.encode() + data)
        self.process.stdin.flush()

    def request(self, method, params, timeout=120):
        self.ident += 1
        self.send(method, params, self.ident)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            pos = self.buffer.find(b'\r\n\r\n')
            if pos >= 0:
                size = int(bytes(self.buffer[:pos]).split(b':')[1].strip())
                if len(self.buffer) >= pos + 4 + size:
                    message = json.loads(bytes(self.buffer[pos+4:pos+4+size]))
                    del self.buffer[:pos+4+size]
                    if message.get('method') == 'textDocument/publishDiagnostics':
                        self.diagnostics[message['params']['uri']] = message['params']
                    if message.get('id') == self.ident:
                        if 'error' in message:
                            raise AssertionError(message['error'])
                        return message['result']
                    continue
            if select.select([self.process.stdout], [], [], 0.2)[0]:
                data = os.read(self.process.stdout.fileno(), 65536)
                if not data:
                    raise AssertionError('daemon exited before replying')
                self.buffer.extend(data)
        raise TimeoutError(method)

    def idle(self):
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            state = self.request('nimdex/debug', {'summaryOnly': True})
            if not state['semantic']['loading']:
                return state
            time.sleep(0.02)
        raise TimeoutError('analysis did not settle')


def sample_memory(pid, stopped, peaks):
    while not stopped.wait(0.25):
        rows = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,rss=']).decode()
        processes = {int(p): (int(parent), int(rss)) for p, parent, rss in
                     (line.split() for line in rows.splitlines())}
        descendants = {pid}
        while True:
            found = {p for p, (parent, _) in processes.items() if parent in descendants}
            if found <= descendants:
                break
            descendants |= found
        peaks['serverKiB'] = max(peaks['serverKiB'], processes.get(pid, (0, 0))[1])
        peaks['compilerTreeKiB'] = max(peaks['compilerTreeKiB'], sum(
            processes[p][1] for p in descendants if p != pid and p in processes))


def run(args, root):
    main, support = root/'main.nim', root/'support.nim'
    support.write_text('proc value0*(): int {.raises: [ValueError].} = 0\n')
    main.write_text('import support\ndiscard value0()\n')
    with (root/'daemon.stderr').open('w') as log:
        client = Client(args.server, root, log)
        stop = threading.Event()
        peaks = {'serverKiB': 0, 'compilerTreeKiB': 0}
        sampler = threading.Thread(target=sample_memory,
            args=(client.process.pid, stop, peaks), daemon=True)
        sampler.start()
        try:
            client.request('initialize', {'rootUri': root.as_uri(), 'capabilities': {},
                'initializationOptions': {'compilerPath': str(args.nim),
                    'entryPoints': [str(main)], 'cacheRoot': str(root/'cache')}})
            client.send('initialized', {})
            client.idle()
            for cycle in range(args.cycles):
                began = time.monotonic()
                for path in (support, main):
                    client.send('textDocument/didOpen', {'textDocument': {
                        'uri': path.as_uri(), 'version': 1, 'text': path.read_text()}})
                # Four revisions arrive in one burst. Every cycle has distinct
                # symbols, catching retention hidden by byte-identical saves.
                for edit in range(4):
                    version = edit + 2
                    name = f'value{cycle+1}_{edit}'
                    texts = ((support, f'proc {name}*(): int {{.raises: [ValueError].}} = {cycle}\n'),
                             (main, f'import support\ndiscard {name}()\n'))
                    for path, text in texts:
                        client.send('textDocument/didChange', {'textDocument': {
                            'uri': path.as_uri(), 'version': version},
                            'contentChanges': [{'text': text}]})
                if args.saved:
                    for path, text in texts:
                        path.write_text(text)
                    client.send('textDocument/didSave', {'textDocument': {'uri': main.as_uri()}})
                client.idle()
                params = {'textDocument': {'uri': support.as_uri()}}
                symbols = client.request('textDocument/documentSymbol', params)
                assert any(s['name'] == name for s in symbols), symbols
                if not args.saved:
                    params = {'textDocument': {'uri': main.as_uri()},
                              'position': {'line': 1, 'character': 10}}
                    definition = client.request('textDocument/definition', params)
                    assert len(definition) == 1, definition
                    assert definition[0]['uri'] == support.as_uri(), definition
                    hover = client.request('textDocument/hover', params)
                    assert 'raises: [ValueError]' in hover['contents']['value'], hover
                    if cycle % 10 == 0:
                        client.send('textDocument/didChange', {'textDocument': {
                            'uri': support.as_uri(), 'version': 6},
                            'contentChanges': [{'text': 'proc broken( = discard\n'}]})
                        client.idle()
                        diagnostics = client.diagnostics[support.as_uri()]
                        assert diagnostics['version'] == 6 and diagnostics['diagnostics'], diagnostics
                for path in (support, main):
                    client.send('textDocument/didClose', {'textDocument': {'uri': path.as_uri()}})
                state = client.idle()
                assert not state['refresh']['failedHeads'], state['refresh']
                rss = int(subprocess.check_output(['ps', '-o', 'rss=', '-p', str(client.process.pid)]))
                print(json.dumps({'cycle': cycle, 'rssKiB': rss,
                    'seconds': round(time.monotonic()-began, 3),
                    'retiredWorkers': state['refresh'].get('retiredWorkers')}), flush=True)
            client.request('shutdown', {})
            client.send('exit', {})
            client.process.wait(timeout=10)
            assert client.process.returncode == 0
            print(json.dumps({'observedPeaks': peaks, 'cycles': args.cycles}), flush=True)
        finally:
            stop.set()
            sampler.join(timeout=2)
            if client.process.poll() is None:
                client.process.kill()
                client.process.wait()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--server', type=Path, required=True)
    parser.add_argument('--nim', type=Path, default=Path(__file__).resolve().parents[1]/'deps/nim-devel/bin/nim')
    parser.add_argument('--cycles', type=int, default=50)
    parser.add_argument('--saved', action='store_true')
    parser.add_argument('--keep', action='store_true', help='keep the fixture and stderr log')
    args = parser.parse_args()
    args.server, args.nim = args.server.resolve(), args.nim.resolve()
    if args.keep:
        root = Path(tempfile.mkdtemp(prefix='nimdex-soak-')).resolve()
        print(json.dumps({'fixture': str(root)}), flush=True)
        run(args, root)
    else:
        with tempfile.TemporaryDirectory(prefix='nimdex-soak-') as directory:
            run(args, Path(directory).resolve())
