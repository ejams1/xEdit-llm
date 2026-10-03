"""Classic TES4 native VWD resource predicate and override persistence fixture."""
import argparse
from pathlib import Path
import struct
from itm_fixture import Client, subrecord
from localization_fixture import reject

SCENE, OUTPUT = 'AutomationVWDScene.esp', 'AutomationVWDOutput.esp'

def record(sig, body, identity=0, flags=0):
    return struct.pack('<4sIIII', sig, len(body), flags, identity, 0) + body

def group(label, kind, body):
    if isinstance(label, int): label = struct.pack('<I', label)
    return struct.pack('<4sI4sIHH', b'GRUP', 20 + len(body), label, kind, 0, 0) + body

def header(count):
    body = subrecord(b'HEDR', struct.pack('<fII', 1.0, count, 0x900))
    body += subrecord(b'MAST', b'Oblivion.esm\0') + subrecord(b'DATA', b'\0' * 8)
    return record(b'TES4', body)

def reference(name, identity, base, flags=0):
    body = subrecord(b'EDID', name.encode() + b'\0') + subrecord(b'NAME', struct.pack('<I', base))
    body += subrecord(b'DATA', struct.pack('<6f', 100, 200, 300, 0, 0, 0))
    return record(b'REFR', body, identity, flags)

def fixtures():
    statics = b''
    for index, model in enumerate(('automation\\eligible.nif', 'automation\\missing.nif'), 0x800):
        body = subrecord(b'EDID', ('VWDStatic' + str(index)).encode() + b'\0')
        body += subrecord(b'MODL', model.encode() + b'\0') + subrecord(b'MODB', struct.pack('<f', 10))
        statics += record(b'STAT', body, 0x01000000 + index)
    world = record(b'WRLD', subrecord(b'EDID', b'VWDWorld\0') + subrecord(b'DATA', b'\0'), 0x01000810)
    exterior = record(b'CELL', subrecord(b'EDID', b'VWDExterior\0') + subrecord(b'DATA', b'\0') + subrecord(b'XCLC', struct.pack('<ii', 0, 0)), 0x01000820)
    refs = reference('Eligible', 0x01000830, 0x01000800)
    refs += reference('MissingResource', 0x01000831, 0x01000801)
    refs += reference('AlreadyVWD', 0x01000832, 0x01000800, 0x8000)
    child = group(0x01000820, 6, group(0x01000820, 9, refs))
    world_children = group(0x01000810, 1, group(0, 4, group(0, 5, exterior + child)))
    interior = record(b'CELL', subrecord(b'EDID', b'VWDInterior\0') + subrecord(b'DATA', b'\1'), 0x01000821)
    interior_children = group(0x01000821, 6, group(0x01000821, 9, reference('Interior', 0x01000833, 0x01000800)))
    return {SCENE: header(9) + group(b'STAT', 0, statics) + group(b'WRLD', 0, world + world_children)
            + group(b'CELL', 0, group(0, 2, group(0, 3, interior + interior_children))), OUTPUT: header(0)}

def flags_on_disk(path):
    result = {}
    data = path.read_bytes()
    def visit(start, end):
        while start < end:
            sig, size = struct.unpack_from('<4sI', data, start)
            if sig == b'GRUP': visit(start + 20, start + size); start += size; continue
            flags, identity = struct.unpack_from('<II', data, start + 8)
            if sig == b'REFR': result[identity & 0xFFFFFF] = bool(flags & 0x8000)
            start += size + 20
        assert start == end
    visit(0, len(data))
    return result

def exercise(client, overlay, verify=False):
    rows = client.call('records.list', file=SCENE, signature='REFR')['records']
    by_name = {row['object']['editorId']: row['locator'] for row in rows}
    assert set(by_name) == {'Eligible', 'MissingResource', 'AlreadyVWD', 'Interior'}
    def vwd(locator):
        value = client.call('elements.get_value', **{**locator, 'path': 'Record Header\\Record Flags'})['values']['nativeValue']['value']
        return bool(int(value) & 0x8000)
    if verify:
        assert {name: vwd(loc) for name, loc in by_name.items()} == {'Eligible': True, 'MissingResource': False, 'AlreadyVWD': True, 'Interior': False}
        assert flags_on_disk(overlay / SCENE) == {0x830: True, 0x831: False, 0x832: True, 0x833: False}
        assert flags_on_disk(overlay / OUTPUT) == {0x830: True}
        target_rows = client.call('records.list', file=OUTPUT, signature='REFR')['records']
        assert len(target_rows) == 1 and target_rows[0]['object']['editorId'] == 'Eligible', target_rows
        target = target_rows[0]['locator']
        assert target['file'] == OUTPUT and target['formId'] == by_name['Eligible']['formId'] and vwd(target)
        assert client.call('files.get', name=OUTPUT)['file']['masters'] == ['Oblivion.esm', SCENE]
        link = client.call('elements.edit_capabilities', **{**target, 'path': 'NAME'})['reference']
        assert link['resolved'] and link['locator']['file'] == SCENE, link
        statics = client.call('records.list', file=SCENE, signature='STAT')['records']
        base = next(row['locator'] for row in statics if row['object']['editorId'] == 'VWDStatic2048')
        assert link['locator'] == base, (link, base)
        return
    before = client.call('session.get_dirty_state')
    plan = client.call('records.set_vwd_from_mesh', files=[SCENE], targetFile=OUTPUT)
    assert plan['dryRun'] and plan['planned'] == 1 and plan['applied'] == 0, plan
    skip = {row['editorId']: row.get('skipReason') for row in plan['records']}
    assert skip == {'Eligible': None, 'MissingResource': 'no-vwd-resource', 'AlreadyVWD': 'already-vwd', 'Interior': 'interior'}, skip
    assert client.call('session.get_dirty_state')['mutationRevision'] == before['mutationRevision']
    result = client.call('records.set_vwd_from_mesh', files=[SCENE], targetFile=OUTPUT, dryRun=False)
    assert result['complete'] and result['applied'] == 1, result
    assert not vwd(by_name['Eligible'])
    target_rows = client.call('records.list', file=OUTPUT, signature='REFR')['records']
    assert len(target_rows) == 1 and vwd(target_rows[0]['locator'])
    revision = client.call('session.get_dirty_state')['mutationRevision']
    reject(client, 'records.set_vwd_from_mesh', files=[SCENE], targetFile=OUTPUT)
    assert client.call('session.get_dirty_state')['mutationRevision'] == revision
    local = client.call('records.set_vwd_from_mesh', files=[SCENE], dryRun=False)
    assert local['complete'] and local['applied'] == 1 and vwd(by_name['Eligible'])
    again = client.call('records.set_vwd_from_mesh', files=[SCENE])
    assert again['planned'] == 0
    client.call('session.save', files=[SCENE, OUTPUT]); client.call('session.flush')
    assert flags_on_disk(overlay / SCENE)[0x830] and flags_on_disk(overlay / OUTPUT)[0x830]

def main():
    p = argparse.ArgumentParser(__doc__)
    p.add_argument('phase', choices=('generate', 'exercise', 'verify'))
    p.add_argument('--overlay', type=Path, required=True)
    p.add_argument('--exe', type=Path); p.add_argument('--pid', type=int); p.add_argument('--artifacts', type=Path)
    a = p.parse_args()
    if a.phase == 'generate':
        a.overlay.mkdir(parents=True, exist_ok=True)
        for name, data in fixtures().items(): (a.overlay / name).write_bytes(data)
        # Native predicate only opens resource presence; no geometry is decoded.
        # This marker tests that exact predicate and is not a rendering asset.
        mesh = a.overlay / 'meshes' / 'automation' / 'eligible_far.nif'
        mesh.parent.mkdir(parents=True, exist_ok=True); mesh.write_bytes(b'VWD presence fixture')
        (a.overlay / 'plugins.txt').write_text('Oblivion.esm\n' + SCENE + '\n' + OUTPUT + '\n')
    else:
        if not all((a.exe, a.pid, a.artifacts)): p.error('Live phases require exe/pid/artifacts')
        exercise(Client(a.exe, a.pid, a.artifacts), a.overlay, a.phase == 'verify')

if __name__ == '__main__': main()
