"""Interior native flag AND group migration, with raw disk and fresh-session readback."""
import argparse
import json
from pathlib import Path
import struct
from itm_fixture import Client
from report_fixture import fixtures as scenes, BASE, QUICK


def refs(data, size):
    result = {}
    def walk(start, end, kind=None):
        while start < end:
            sig, length = struct.unpack_from('<4sI', data, start)
            if sig == b'GRUP':
                walk(start + size, start + length, struct.unpack_from('<I', data, start + 12)[0])
                start += length
            else:
                if sig == b'REFR':
                    flags, identity = struct.unpack_from('<II', data, start + 8)
                    result[identity & 0xFFFFFF] = (flags, kind)
                start += size + length
        assert start == end
    walk(0, len(data))
    return result


def fixtures(game):
    scene = scenes(game)
    size = 20 if game == 'tes4' else 24
    data = bytearray(scene[QUICK])
    def clear_deleted(start, end):
        while start < end:
            sig, length = struct.unpack_from('<4sI', data, start)
            if sig == b'GRUP': clear_deleted(start + size, start + length); start += length
            else:
                if sig == b'REFR': struct.pack_into('<I', data, start + 8, 0)
                start += size + length
    clear_deleted(0, len(data))
    return {BASE: scene[BASE], QUICK: bytes(data)}


def locator(client):
    rows = client.call('records.list', file=QUICK, signature='REFR')['records']
    assert len(rows) == 1, rows
    return rows[0]['locator']


def verify(client, overlay, game):
    loc = locator(client)
    value = client.call('elements.get_value', **{**loc, 'path': 'Record Header\\Record Flags'})
    flags = int(value['values']['nativeValue']['value'])
    assert flags & 0x8000 and not flags & 0x400
    group = 10 if game == 'tes4' else 9
    assert refs((overlay / QUICK).read_bytes(), 20 if game == 'tes4' else 24)[0x830] == (flags, group)


def exercise(client, overlay, game):
    loc = locator(client)
    before = client.call('session.get_dirty_state')
    position = client.call('elements.get_value', **{**loc, 'path': 'DATA'})['values']
    disk = (overlay / QUICK).read_bytes()
    plan = client.call('records.set_reference_flags', records=[loc], persistent=True)
    assert plan['dryRun'] and plan['records'][0]['plannedGroupType'] == 8
    assert client.call('session.get_dirty_state')['mutationRevision'] == before['mutationRevision']
    bad = client.request(json.dumps({'command': 'records.set_reference_flags', 'args': {
        'records': [{**loc, 'expectedPersistent': True}], 'persistent': True, 'dryRun': False}}))
    assert not bad['ok'], bad
    for persistent, vwd, group in ((True, False, 8), (True, True, 8),
                                    (False, True, 10 if game == 'tes4' else 9)):
        result = client.call('records.set_reference_flags', records=[loc], persistent=persistent,
                             visibleWhenDistant=vwd, dryRun=False)
        assert result['complete'] and result['records'][0]['actualGroupType'] == group, result
        assert result['records'][0]['actualCell'] == result['records'][0]['plannedCell']
        assert client.call('elements.get_value', **{**loc, 'path': 'DATA'})['values'] == position
        assert locator(client) == loc
    no_op = client.call('records.set_reference_flags', records=[loc], persistent=False,
                        visibleWhenDistant=True, dryRun=False)
    assert no_op['complete'] and not no_op['changed'], no_op
    assert (overlay / QUICK).read_bytes() == disk
    client.call('session.save', files=[QUICK]); client.call('session.flush')


def main():
    p = argparse.ArgumentParser(__doc__)
    p.add_argument('phase', choices=('generate', 'exercise', 'verify'))
    p.add_argument('--game', choices=('fo4', 'tes4'), default='fo4')
    p.add_argument('--overlay', type=Path, required=True)
    p.add_argument('--exe', type=Path); p.add_argument('--pid', type=int); p.add_argument('--artifacts', type=Path)
    a = p.parse_args()
    if a.phase == 'generate':
        a.overlay.mkdir(parents=True, exist_ok=True)
        for name, data in fixtures(a.game).items():
            with (a.overlay / name).open('xb') as stream: stream.write(data)
        with (a.overlay / 'plugins.txt').open('x') as stream:
            stream.write(('Oblivion.esm' if a.game == 'tes4' else 'Fallout4.esm') + '\n' + BASE + '\n' + QUICK + '\n')
    else:
        if not all((a.exe, a.pid, a.artifacts)): p.error('Live phases require exe/pid/artifacts')
        client = Client(a.exe, a.pid, a.artifacts)
        if a.phase == 'exercise': exercise(client, a.overlay, a.game)
        else: verify(client, a.overlay, a.game)


if __name__ == '__main__': main()
