"""Loopback TCP proxy in front of the SMB fixture that can reset its live connections.

A NAS (or iOS, while the app is suspended) can drop an idle connection without the app
noticing. Stopping the fixture server closes connections with a FIN, which the client reads
as end-of-file. This proxy reproduces the other case: the connection is reset (RST), so the
app's next write to it fails at the socket (EPIPE, and SIGPIPE unless ignored). That is how
Mango died on the phone on 2026-10-26: launchd logged "exited due to SIGPIPE" as a chapter
turn sent the NAS client's echo.

Tests write {"id", "nonce", "action": "reset"} to <root>/.connection-reset/request.json; the
proxy aborts every live client connection with SO_LINGER 0 and answers in response.json with
how many it reset. Only loopback addresses are used.
"""
import argparse
import asyncio
import json
import socket
import struct
import uuid
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--root', type=Path, default=Path('/tmp/mango-earmark-smb-fixtures'))
parser.add_argument('--listen', type=int, default=1448)
parser.add_argument('--upstream', type=int, default=1445)
args = parser.parse_args()
root = args.root.resolve()
if not (root / '.simulator-smb-audit').exists():
    parser.error('Start the generated SMB fixture (smb_fixture.py or service_control.py) with this --root first')
control = root / '.connection-reset'
control.mkdir(exist_ok=True)
for name in ['request.json', 'response.json', 'session.json']:
    (control / name).unlink(missing_ok=True)
nonce = str(uuid.uuid4())
live = set()


def write_json(name, value):
    temporary = control / (name + '.new')
    temporary.write_text(json.dumps(value))
    temporary.replace(control / name)


async def pump(reader, writer):
    try:
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
    except (ConnectionError, OSError):
        pass
    finally:
        writer.close()


async def handle(client_reader, client_writer):
    try:
        upstream_reader, upstream_writer = await asyncio.open_connection('127.0.0.1', args.upstream)
    except OSError:
        client_writer.close()
        return
    pair = (client_writer, upstream_writer)
    live.add(pair)
    print(f'[proxy] connection {len(live)} open', flush=True)
    try:
        await asyncio.gather(pump(client_reader, upstream_writer), pump(upstream_reader, client_writer))
    finally:
        live.discard(pair)


def reset_all():
    count = 0
    for client_writer, upstream_writer in list(live):
        sock = client_writer.get_extra_info('socket')
        if sock is not None:
            # Linger 0: close() sends RST instead of FIN.
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('ii', 1, 0))
        client_writer.transport.abort()
        upstream_writer.transport.abort()
        count += 1
    live.clear()
    print(f'[proxy] reset {count} connection(s)', flush=True)
    return count


async def watch_requests():
    last = None
    while True:
        await asyncio.sleep(0.02)
        try:
            request = json.loads((control / 'request.json').read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            continue
        if request.get('nonce') != nonce or request.get('id') == last:
            continue
        last = request['id']
        if request.get('action') != 'reset':
            raise RuntimeError(f"Unknown connection-reset action: {request.get('action')}")
        write_json('response.json', {'id': last, 'nonce': nonce, 'reset': reset_all()})


async def main():
    server = await asyncio.start_server(handle, '127.0.0.1', args.listen)
    write_json('session.json', {'nonce': nonce})
    print(f'Connection-reset proxy 127.0.0.1:{args.listen} -> 127.0.0.1:{args.upstream} ready: {control}', flush=True)
    try:
        async with server:
            await asyncio.gather(server.serve_forever(), watch_requests())
    finally:
        (control / 'session.json').unlink(missing_ok=True)

try:
    asyncio.run(main())
except KeyboardInterrupt:
    pass
