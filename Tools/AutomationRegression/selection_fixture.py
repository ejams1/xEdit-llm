"""Bounded file/group copy/removal, exact payloads, shallow parent scope and reload."""
import argparse
from pathlib import Path
import struct
from itm_fixture import Client, subrecord, record
from report_fixture import fixtures as reports, BASE, signatures
from localization_fixture import reject

SCENE = 'AutomationSelectionScene.esm'
WHOLE = 'AutomationSelectionWhole.esp'
GROUP = 'AutomationSelectionGroup.esp'
NESTED = 'AutomationSelectionNested.esp'
SHALLOW = 'AutomationSelectionShallow.esp'
TARGETS = (WHOLE, GROUP, NESTED, SHALLOW)

def fixtures():
    empty = record(b'TES4', subrecord(b'HEDR', struct.pack('<fII', 1.0, 0, 0x900)) +
                   subrecord(b'MAST', b'Fallout4.esm\0') + subrecord(b'DATA', b'\0' * 8))
    return {SCENE: reports('fo4')[BASE], **{name: empty for name in TARGETS}}

def select(file): return {'kind': 'file', 'file': file}

def inventory(client, file):
    result = client.call('records.list', file=file, limit=100)
    assert not result['truncated'], result
    return {int(row['locator']['formId'], 16) & 0xFFFFFF: row for row in result['records']
            if row['object']['signature'] != 'TES4'}

def value(client, locator, path):
    return client.call('elements.get_value', **{**locator, 'path': path})['values']['editValue']

def verify(client, overlay=None):
    source = inventory(client, SCENE)
    expected = {WHOLE: set(source), NESTED: {0x820, 0x830, 0x831}, SHALLOW: {0x820, 0x830}}
    for file, ids in expected.items():
        target = inventory(client, file)
        assert set(target) == ids, (file, target)
        for identity in ids:
            loc, original = target[identity]['locator'], source[identity]['locator']
            signature = source[identity]['object']['signature']
            assert target[identity]['object']['signature'] == signature
            if signature != 'NAVM':
                expected_edid = 'PreservedShallowChild' if file == SHALLOW and identity == 0x830 else value(client, original, 'EDID')
                assert value(client, loc, 'EDID') == expected_edid, (file, identity)
            if signature == 'REFR':
                assert value(client, loc, r'DATA\Position\X') == value(client, original, r'DATA\Position\X')
                assert value(client, loc, 'NAME') == value(client, original, 'NAME')
        assert client.call('files.get', name=file)['file']['masters'] == ['Fallout4.esm', SCENE]
        if overlay:
            disk_ids = {identity for sig, identity, _ in signatures((overlay / file).read_bytes(), 24) if sig != b'TES4'}
            assert disk_ids == ids, (file, disk_ids, ids)
            for row in target.values():
                if 'editorId' in row['object']: assert row['object']['editorId'].encode() + b'\0' in (overlay / file).read_bytes()
    group = inventory(client, GROUP)
    assert len(group) == 1 and next(iter(group.values()))['object']['editorId'] == 'SelectedGroupRecord'
    assert next(iter(group.values()))['object']['signature'] == 'FLST'
    assert client.call('files.get', name=GROUP)['file']['masters'] == ['Fallout4.esm', SCENE]
    if overlay:
        assert (overlay / SCENE).read_bytes() == fixtures()[SCENE]
        assert b'SelectedGroupRecord\0' in (overlay / GROUP).read_bytes()
        assert all(sig != b'KYWD' for sig, _, _ in signatures((overlay / GROUP).read_bytes(), 24))

def exercise(client, overlay):
    before = client.call('session.get_dirty_state')
    scene = client.call('selections.inspect', selections=[select(SCENE)])
    assert scene['complete'] and len(scene['records']) == 6
    def group_of(kind):
        return next(row['selector'] for row in scene['groups'] if row['selector']['groupPath'][-1]['type'] == kind)
    keyword = next(row['selector'] for row in scene['groups'] if row['selector']['groupPath'] == [{'type': 0, 'label': f'{int.from_bytes(b"KYWD", "little"):08X}'}])
    nested = group_of(9)
    for targets in ([select(SCENE), keyword], [keyword, keyword]):
        reject(client, 'selections.copy_into', selections=targets, targetFile=GROUP, dryRun=False)
    reject(client, 'selections.remove', selections=[select(SCENE)], dryRun=False)
    reject(client, 'selections.create_group', file=GROUP, signature='NOPE', dryRun=False)
    reject(client, 'selections.inspect', selections=[{'kind': 'group', 'file': SCENE, 'groupPath': [{'type': 0, 'label': '1'}]}])
    assert client.call('session.get_dirty_state') == before
    for target, selections, count in ((WHOLE, [select(SCENE)], 6), (GROUP, [keyword], 2), (NESTED, [nested], 3)):
        plan = client.call('selections.copy_into', selections=selections, targetFile=target)
        assert plan['dryRun'] and plan['plannedRecords'] == count and not plan['changed']
        applied = client.call('selections.copy_into', selections=selections, targetFile=target, dryRun=False)
        assert applied['complete'] and applied['completedRecords'] == count and applied['changed'], applied
        assert all(row['outcome'] == 'applied' for row in applied['records'])
    # Explicit shallow parent copying must assign payload yet preserve child scope.
    source = inventory(client, SCENE)
    for identity in (0x820, 0x830):
        client.call('records.copy_into', source=source[identity]['locator'], target={'file': SHALLOW, 'path': ''}, mode='override', deepCopy=False)
    child = inventory(client, SHALLOW)[0x830]['locator']
    client.call('elements.set_value', **{**child, 'path': 'EDID'}, value='PreservedShallowChild')
    client.call('records.copy_into', source=source[0x820]['locator'], target={'file': SHALLOW, 'path': ''}, mode='override', deepCopy=False, overwrite=True)
    assert set(inventory(client, SHALLOW)) == {0x820, 0x830}
    current = client.call('selections.inspect', selections=[select(GROUP)])
    selected = current['groups'][0]['selector']
    plan = client.call('selections.remove', selections=[selected])
    assert plan['dryRun'] and plan['plannedRecords'] == 2 and not plan['changed']
    removed = client.call('selections.remove', selections=[selected], dryRun=False)
    assert removed['complete'] and removed['changed'] and not removed['diskDeleted']
    assert not inventory(client, GROUP)
    planned_group = client.call('selections.create_group', file=GROUP, signature='FLST')
    assert planned_group['dryRun'] and not planned_group['changed']
    new_group = client.call('selections.create_group', file=GROUP, signature='FLST', dryRun=False)
    assert new_group['changed'] and not new_group['alreadyExists']
    empty_selector = {'kind': 'group', 'file': GROUP, 'groupPath': new_group['groupPath']}
    empty = client.call('selections.copy_into', selections=[empty_selector], targetFile=SHALLOW, dryRun=False)
    assert empty['complete'] and not empty['changed'] and empty['plannedRecords'] == 0
    assert all(row['selector']['groupPath'] != new_group['groupPath'] for row in client.call('selections.inspect', selections=[select(SHALLOW)])['groups'])
    again = client.call('selections.create_group', file=GROUP, signature='FLST', dryRun=False)
    assert not again['changed'] and again['alreadyExists']
    client.call('records.create', targetFile=GROUP, signature='FLST', editorId='SelectedGroupRecord')
    verify(client)
    for file in TARGETS: assert (overlay / file).read_bytes() == fixtures()[file]
    assert (overlay / SCENE).read_bytes() == fixtures()[SCENE]
    client.call('session.save', files=list(TARGETS)); client.call('session.flush')

def main():
    p = argparse.ArgumentParser(__doc__)
    p.add_argument('phase', choices=('generate', 'exercise', 'verify'))
    p.add_argument('--overlay', type=Path, required=True)
    p.add_argument('--exe', type=Path); p.add_argument('--pid', type=int); p.add_argument('--artifacts', type=Path)
    a = p.parse_args()
    if a.phase == 'generate':
        a.overlay.mkdir(parents=True, exist_ok=True)
        files = fixtures()
        if any((a.overlay / name).exists() for name in (*files, 'plugins.txt')): p.error('Choose a fresh overlay')
        for name, data in files.items(): (a.overlay / name).write_bytes(data)
        (a.overlay / 'plugins.txt').write_text('\n'.join(('Fallout4.esm', SCENE, *TARGETS)) + '\n')
    else:
        if not all((a.exe, a.pid, a.artifacts)): p.error('Live phases require exe/pid/artifacts')
        client = Client(a.exe, a.pid, a.artifacts)
        if a.phase == 'exercise': exercise(client, a.overlay)
        else: verify(client, a.overlay)

if __name__ == '__main__': main()
