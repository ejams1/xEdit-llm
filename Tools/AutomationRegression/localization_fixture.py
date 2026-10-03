"""FO4 localization scene and independent binary/string-table acceptance.

Generate into a dedicated MO2 overlay. Each live phase needs a fresh daemon;
table outputs must be projected as that overlay's Strings directory.
"""
import argparse
from pathlib import Path
import struct
from itm_fixture import Client, record, subrecord

PLUGIN = 'AutomationLocalization.esp'
VALUES = {'SharedA': ('Shared text', ' \t' + 'long text ' * 40 + '\n '),
          'SharedB': ('Shared text', ''), 'Unicode': ('日本語 Привет 😀', 'Français')}
EDITED = '  edited 日本語 😀\n '
TABLES = {'STRINGS': {1: 'Shared text', 3: VALUES['Unicode'][0]},
          'DLSTRINGS': {2: VALUES['SharedA'][1], 4: 'Français'},
          'ILSTRINGS': {5: '  independent dialogue Привет\n '}}

def encode_table(rows, kind):
    directory, payload = b'', b''
    for identity, text in rows.items():
        value = text.encode('utf-8') + b'\0'
        if kind != 'STRINGS': value = struct.pack('<I', len(value)) + value
        directory += struct.pack('<II', identity, len(payload))
        payload += value
    return struct.pack('<II', len(rows), len(payload)) + directory + payload

def decode_table(data, kind):
    """Decode actual native bytes, independent of command responses."""
    if len(data) < 8: raise ValueError('short header')
    count, size = struct.unpack_from('<II', data)
    start = 8 + count * 8
    if count > 1000000 or start + size != len(data): raise ValueError('directory/size')
    rows = {}
    for index in range(count):
        identity, offset = struct.unpack_from('<II', data, 8 + index * 8)
        if identity in rows or offset >= size: raise ValueError('ID/offset')
        pos = start + offset
        if kind != 'STRINGS':
            length, = struct.unpack_from('<I', data, pos)
            pos += 4
            if not length or pos + length > len(data): raise ValueError('length')
            value = data[pos:pos + length]
            if value[-1] != 0: raise ValueError('terminator')
        else:
            stop = data.find(b'\0', pos)
            if stop < 0: raise ValueError('terminator')
            value = data[pos:stop + 1]
        rows[identity] = value[:-1].decode('utf-8')
    return rows

def plugin_bytes():
    header = subrecord(b'HEDR', struct.pack('<fII', 1.0, 3, 0x900))
    header += subrecord(b'MAST', b'Fallout4.esm\0') + subrecord(b'DATA', b'\0' * 8)
    body = b''
    for index, (name, ids) in enumerate((('SharedA', (1, 2)), ('SharedB', (1, 0)), ('Unicode', (3, 4))), 0x800):
        payload = subrecord(b'EDID', name.encode() + b'\0')
        for sig, identity in zip((b'FULL', b'DESC'), ids): payload += subrecord(sig, struct.pack('<I', identity))
        payload += subrecord(b'DNAM', struct.pack('<I', 0))
        payload += subrecord(b'INAM', struct.pack('<I', 0)) + subrecord(b'TNAM', struct.pack('<I', 2))
        body += record(b'MESG', payload, form_id=0x01000000 + index)
    return record(b'TES4', header, flags=0x80) + struct.pack('<4sI4sIHHHH', b'GRUP', 24 + len(body), b'MESG', 0, 0, 0, 0, 0) + body

def read_plugin(data):
    rows = {}
    def visit(start, end):
        while start < end:
            sig, size = struct.unpack_from('<4sI', data, start)
            if sig == b'GRUP':
                visit(start + 24, start + size); start += size; continue
            pos, stop = start + 24, start + 24 + size
            fields = {}
            while pos < stop:
                sub, length = struct.unpack_from('<4sH', data, pos)
                fields[sub.decode()] = data[pos + 6:pos + 6 + length]
                pos += 6 + length
            if sig == b'MESG': rows[fields['EDID'].rstrip(b'\0').decode()] = fields
            start = stop
    visit(0, len(data))
    return bool(struct.unpack_from('<I', data, 8)[0] & 0x80), rows

def expected(name):
    full, desc = VALUES[name]
    return (EDITED if name.startswith('Shared') else full), desc

def reject(client, command, **args):
    try: client.call(command, **args)
    except RuntimeError: return
    raise AssertionError(f'{command} unexpectedly succeeded')

def exercise(client, overlay, phase):
    localized = phase != 'relocalize'
    listing = client.call('records.list', file=PLUGIN, signature='MESG')['records']
    locators = {row['object']['editorId']: row['locator'] for row in listing}
    assert set(locators) == set(VALUES)
    for name, loc in locators.items():
        for field, value in zip(('FULL', 'DESC'), VALUES[name] if phase == 'delocalize' else expected(name)):
            assert client.call('elements.get_value', **{**loc, 'path': field})['values']['editValue'] == value
    tables = client.call('localization.tables', file=PLUGIN)
    assert tables['localized'] == localized, tables
    if phase == 'verify':
        verify_disk(overlay, True)
        return
    if phase == 'delocalize':
        args = dict(file=PLUGIN, type='STRINGS', id='00000001')
        client.call('localization.set', **args, expectedValue='Shared text', value=EDITED)
        assert client.call('localization.get', **args)['value'] == EDITED
        for name in ('SharedA', 'SharedB'):
            assert client.call('elements.get_value', **{**locators[name], 'path': 'FULL'})['values']['editValue'] == EDITED
        before = client.call('session.get_dirty_state')
        assert before['dirty'] and before['dirtyLocalizationTableCount'] == 1
        reject(client, 'localization.language', language='french')
        reject(client, 'localization.set', **args, expectedValue='stale', value='x')
        reject(client, 'session.flush')
        assert client.call('localization.get', **args)['value'] == EDITED
        out = client.call('localization.export_text', file=PLUGIN, outputDirectory=str(overlay / 'Strings'), overwrite=True)
        assert out['complete'] and client.call('session.get_dirty_state')['dirtyLocalizationTableCount'] == 1
        assert EDITED in (overlay / 'Strings' / 'AutomationLocalization_english.STRINGS.txt').read_text(encoding='utf-8')
    mode = 'localize' if phase == 'relocalize' else 'delocalize'
    plan = client.call('localization.convert', file=PLUGIN, mode=mode)
    assert plan['dryRun'] and not plan['changed']
    result = client.call('localization.convert', file=PLUGIN, mode=mode, dryRun=False, reuseDuplicates=True)
    assert result['complete'] and result['changed'] and result['restartRequired'], result
    reject(client, 'elements.set_value', **{**locators['SharedA'], 'path': 'FULL'}, value='blocked')
    saved = client.call('localization.save', file=PLUGIN, outputDirectory=str(overlay / 'Strings'), overwrite=True)
    assert saved['complete'] and saved['dirtyLocalizationTableCount'] == 0, saved
    client.call('session.save', files=[PLUGIN])
    client.call('session.flush')
    verify_disk(overlay, phase == 'relocalize')

def verify_disk(overlay, localized):
    flag, rows = read_plugin((overlay / PLUGIN).read_bytes())
    assert flag == localized
    tables = {kind: decode_table((overlay / 'Strings' / f'AutomationLocalization_english.{kind}').read_bytes(), kind) for kind in TABLES}
    for name, fields in rows.items():
        for field, kind, value in zip(('FULL', 'DESC'), ('STRINGS', 'DLSTRINGS'), expected(name)):
            raw = fields[field]
            if localized:
                assert len(raw) == 4
                identity, = struct.unpack('<I', raw)
                actual = '' if identity == 0 else tables[kind][identity]
            else: actual = raw.rstrip(b'\0').decode('utf-8')
            assert actual == value, (name, field, actual, value)
    if localized:
        assert rows['SharedA']['FULL'] == rows['SharedB']['FULL']

def main():
    p = argparse.ArgumentParser(__doc__)
    p.add_argument('phase', choices=('generate', 'delocalize', 'relocalize', 'verify'))
    p.add_argument('--overlay', type=Path, required=True)
    p.add_argument('--exe', type=Path); p.add_argument('--pid', type=int); p.add_argument('--artifacts', type=Path)
    a = p.parse_args()
    if a.phase == 'generate':
        a.overlay.mkdir(parents=True, exist_ok=True)
        (a.overlay / PLUGIN).write_bytes(plugin_bytes())
        (a.overlay / Path(PLUGIN).with_suffix('.cpoverride')).write_text('65001\n')
        (a.overlay / 'Strings').mkdir(exist_ok=True)
        for kind, rows in TABLES.items():
            path = a.overlay / 'Strings' / f'AutomationLocalization_english.{kind}'
            path.write_bytes(encode_table(rows, kind))
        (a.overlay / 'Strings' / 'AutomationLocalization_english.cpoverride').write_text('65001\n')
        (a.overlay / 'plugins.txt').write_text('Fallout4.esm\n' + PLUGIN + '\n')
    else:
        if not all((a.exe, a.pid, a.artifacts)): p.error('Live phases require exe, pid and artifacts')
        exercise(Client(a.exe, a.pid, a.artifacts), a.overlay, a.phase)

if __name__ == '__main__': main()
