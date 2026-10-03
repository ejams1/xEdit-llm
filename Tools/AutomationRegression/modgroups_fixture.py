"""Native ModGroup configuration and conflict-selection fixture for FO4/MO2."""
import argparse
import hashlib
from pathlib import Path
import struct
from itm_fixture import Client, record, subrecord
from localization_fixture import reject

BASE, LEFT, RIGHT = 'AutomationGroupBase.esm', 'AutomationGroupLeft.esp', 'AutomationGroupRight.esp'
CONFIG = 'AutomationGroupBase.modgroups'
ITEMS = ['@' + LEFT, '#' + RIGHT]
KEEP = '[Keep]\n' + '\n'.join(ITEMS) + '\n'

def fixtures():
    result = {}
    for index, (plugin, edid, masters) in enumerate(((BASE, 'GroupBase', ['Fallout4.esm']),
        (LEFT, 'GroupLeft', ['Fallout4.esm', BASE]), (RIGHT, 'GroupRight', ['Fallout4.esm', BASE, LEFT]))):
        header = subrecord(b'HEDR', struct.pack('<fII', 1.0, 1, 0x900))
        for master in masters: header += subrecord(b'MAST', master.encode() + b'\0') + subrecord(b'DATA', b'\0' * 8)
        row = record(b'KYWD', subrecord(b'EDID', edid.encode() + b'\0'), form_id=0x01000800)
        group = struct.pack('<4sI4sIHHHH', b'GRUP', 24 + len(row), b'KYWD', 0, 0, 0, 0, 0) + row
        result[plugin] = record(b'TES4', header, flags=int(index == 0)) + group
    return result

def exercise(client, overlay, verify=False):
    inventory = client.call('modgroups.list')
    keep = next(g for g in inventory['groups'] if g['name'] == 'Keep' and Path(g['configFile']).name == CONFIG)
    config = keep['configFile']
    rows = client.call('records.list', file=RIGHT, signature='KYWD')['records']
    locator = rows[0]['locator']
    identity = dict(configFile=config, name='Automation')
    state = client.call('session.get_dirty_state')
    client.call('modgroups.activate', groups=[])
    def participants():
        return [row['file'] for row in client.call('records.conflict_status', **locator)['conflict']['participants']]
    assert participants() == [BASE, LEFT, RIGHT]
    if verify:
        automation = next(g for g in inventory['groups'] if g['name'] == 'Automation' and g['configFile'] == config)
        assert automation['valid'] and ':' in automation['items'][1]
        client.call('modgroups.activate', groups=[identity])
        assert participants() == [BASE, RIGHT]
        assert 'Keep' in (overlay / CONFIG).read_text(encoding='utf-8-sig')
        return
    args = dict(configFile=config, name='Automation', operation='create', items=ITEMS, expectedFileHash=keep['fileHash'])
    planned = client.call('modgroups.write', **args)
    assert planned['dryRun'] and not planned['written'] and planned['candidate']['valid']
    assert (overlay / CONFIG).read_text() == KEEP
    created = client.call('modgroups.write', **args, dryRun=False)
    assert created['written']
    reject(client, 'modgroups.write', **args, dryRun=False)
    client.call('modgroups.activate', groups=[identity])
    assert participants() == [BASE, RIGHT]
    client.call('modgroups.activate', groups=[identity], enabled=False)
    assert participants() == [BASE, LEFT, RIGHT]
    client.call('modgroups.activate', groups=[identity])
    client.call('modgroups.reload')
    assert participants() == [BASE, RIGHT]
    refresh = dict(**identity, files=[RIGHT], expectedFileHash=created['fileHash'])
    client.call('modgroups.refresh_crc', **refresh)
    updated = client.call('modgroups.refresh_crc', **refresh, dryRun=False)
    assert updated['written'] and updated['changedCRCItems'] == 1
    listing = client.call('modgroups.list', configFile=config)
    group = next(g for g in listing['groups'] if g['name'] == 'Automation')
    assert ':' not in group['items'][0] and ':' in group['items'][1]
    assert group['fileHash'] == hashlib.sha256((overlay / CONFIG).read_bytes()).hexdigest()
    rename = client.call('modgroups.write', **identity, operation='update', newName='Renamed', items=group['items'], expectedFileHash=group['fileHash'], dryRun=False)
    assert rename['written'] and participants() == [BASE, RIGHT]
    renamed = {**identity, 'name': 'Renamed'}
    deleted = client.call('modgroups.write', **renamed, operation='delete', expectedFileHash=rename['fileHash'], dryRun=False)
    assert deleted['written'] and deleted['droppedGroups']
    assert participants() == [BASE, LEFT, RIGHT]
    final = client.call('modgroups.write', **identity, operation='create', items=group['items'], expectedFileHash=deleted['fileHash'], dryRun=False)
    assert final['written']
    after = client.call('session.get_dirty_state')
    assert state['dirtyFiles'] == after['dirtyFiles'] and state['mutationRevision'] == after['mutationRevision']
    text = (overlay / CONFIG).read_text(encoding='utf-8-sig')
    assert KEEP.replace('\n', '\r\n') in text.replace('\r\n', '\n').replace('\n', '\r\n')

def main():
    p = argparse.ArgumentParser(__doc__)
    p.add_argument('phase', choices=('generate', 'exercise', 'verify'))
    p.add_argument('--overlay', type=Path, required=True)
    p.add_argument('--exe', type=Path); p.add_argument('--pid', type=int); p.add_argument('--artifacts', type=Path)
    a = p.parse_args()
    if a.phase == 'generate':
        a.overlay.mkdir(parents=True, exist_ok=True)
        for name, data in fixtures().items(): (a.overlay / name).write_bytes(data)
        (a.overlay / CONFIG).write_text(KEEP)
        (a.overlay / 'plugins.txt').write_text('\n'.join(['Fallout4.esm', BASE, LEFT, RIGHT]) + '\n')
    else:
        if not all((a.exe, a.pid, a.artifacts)): p.error('Live phases need exe/pid/artifacts')
        exercise(Client(a.exe, a.pid, a.artifacts), a.overlay, a.phase == 'verify')

if __name__ == '__main__': main()
