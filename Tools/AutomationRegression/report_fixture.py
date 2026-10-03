"""Saved FO4/TES4 cleaning snapshots, exact native report counts and UTF-8 export."""
import argparse
from pathlib import Path
import struct
import zlib
from itm_fixture import Client, subrecord, record as modern_record
from vwd_fixture import record as classic_record
from localization_fixture import reject

BASE = 'AutomationReportBase.esm'
DIRTY = 'AutomationReportDirty.esp'
QUICK = 'AutomationReportQuick.esp'
CLEAN = "AutomationReport'Clean.esp"

def fixtures(game='fo4'):
    classic = game == 'tes4'
    master = 'Oblivion.esm' if classic else 'Fallout4.esm'
    size = 20 if classic else 24
    def record(sig, body, identity=0, flags=0):
        if classic: return classic_record(sig, body, identity, flags)
        return modern_record(sig, body, flags, identity)
    def group(label, kind, body):
        if isinstance(label, int): label = struct.pack('<I', label)
        return struct.pack('<4sI4sI', b'GRUP', size + len(body), label, kind) + b'\0' * (size - 16) + body
    def header(masters, count, esm=False):
        body = subrecord(b'HEDR', struct.pack('<fII', 1.0, count, 0x900))
        for name in masters: body += subrecord(b'MAST', name.encode() + b'\0') + subrecord(b'DATA', b'\0' * 8)
        return record(b'TES4', body, flags=int(esm))
    sig = b'GLOB' if classic else b'KYWD'
    def keyword(name, identity, flags=0):
        body = subrecord(b'EDID', name.encode() + b'\0')
        if classic: body += subrecord(b'FNAM', b'f') + subrecord(b'FLTV', struct.pack('<f', 1))
        return record(sig, body, identity, flags)
    itm = keyword('ReportIdentical', 0x01000800)
    flag = keyword('ReportFlagOnly', 0x01000801)
    static = subrecord(b'EDID', b'ReportStatic\0') + subrecord(b'MODL', b'automation\\report.nif\0')
    if not classic: static += subrecord(b'OBND', b'\0' * 12)
    cell = record(b'CELL', subrecord(b'EDID', b'ReportInterior\0') + subrecord(b'DATA', b'\1' + (b'' if classic else b'\0')), 0x01000820)
    def refs(deleted=False, nav=False):
        body = subrecord(b'EDID', b'ReportDeletedRef\0') + subrecord(b'NAME', struct.pack('<I', 0x01000810))
        body += subrecord(b'DATA', struct.pack('<6f', 100, 200, 300, 0, 0, 0))
        result = record(b'REFR', body, 0x01000830, 0x20 if deleted else 0)
        # Deleted NAVM requires manual repair even when no geometry is present.
        # Geometry rendering/validation is not part of this report fixture.
        if nav: result += record(b'NAVM', b'', 0x01000831, 0x20 if deleted else 0)
        return group(b'CELL', 0, group(0, 2, group(0, 3, cell + group(0x01000820, 6, group(0x01000820, 9, result)))))
    base = header([master], 5 if classic else 6, True) + group(sig, 0, itm + flag)
    base += group(b'STAT', 0, record(b'STAT', static, 0x01000810)) + refs(nav=not classic)
    changed_flag = keyword('ReportFlagOnly', 0x01000801, 0x80000000)
    result = {BASE: base, CLEAN: header([master, BASE], 0)}
    for name, nav in ((DIRTY, not classic), (QUICK, False)):
        result[name] = header([master, BASE], 4 + int(nav)) + group(sig, 0, itm + changed_flag) + refs(True, nav)
    return result

def signatures(data, size):
    result = []
    def visit(start, end):
        while start < end:
            sig, length = struct.unpack_from('<4sI', data, start)
            if sig == b'GRUP': visit(start + size, start + length); start += length
            else:
                flags, identity = struct.unpack_from('<II', data, start + 8)
                result.append((sig, identity & 0xFFFFFF, flags))
                start += size + length
        assert start == end
    visit(0, len(data))
    return result

def check(client, overlay, game):
    before = client.call('session.get_dirty_state')
    assert not before['dirty'] and not before['pendingShutdownCount'], before
    report = client.call('reports.cleaning', format='loot', files=[DIRTY, QUICK, CLEAN])
    expected = [(1, 1, int(game == 'fo4')), (1, 1, 0), (0, 0, 0)]
    assert report['complete'] and [row['file'] for row in report['files']] == [DIRTY, QUICK, CLEAN]
    for row, counts in zip(report['files'], expected):
        assert row['counts'] == dict(zip(('itm', 'udr', 'nav'), counts)), row
        for category, count in zip(('itm', 'udr', 'nav'), counts):
            assert len(row[category]) == count
            if count:
                item = row[category][0]
                assert item['file'] == row['file'] and int(item['formId'], 16) & 0xFFFFFF == {'itm': 0x800, 'udr': 0x830, 'nav': 0x831}[category]
                resolved = client.call('records.get', **{k: item[k] for k in ('file', 'formId', 'path')})
                assert resolved['object']['signature'] == item['signature']
        if row['file'] in (DIRTY, QUICK):
            assert any(int(item['formId'], 16) & 0xFFFFFF == 0x820 and item['reason'] == 'itm-has-children' for item in row['skipped'])
        assert row['crc32'] == f'{zlib.crc32((overlay / row["file"]).read_bytes()):08X}'
        assert 'crc: 0x' + row['crc32'] in row['text']
        if counts[2]: assert '*reqManualFix' in row['text'] and 'nav: 1' in row['text']
        elif counts[0] or counts[1]: assert '*quickClean' in row['text'] and 'itm: 1' in row['text'] and 'udr: 1' in row['text']
        else: assert "AutomationReport''Clean.esp" in row['text'] and 'clean:' in row['text'] and 'dirty:' not in row['text']
    assert report['text'] == ''.join(row['text'] for row in report['files'])
    assert client.call('session.get_dirty_state') == before
    return report

def exercise(client, overlay, output, game):
    report = check(client, overlay, game)
    planned = client.call('reports.cleaning', format='loot', files=[DIRTY, QUICK, CLEAN], outputDirectory=str(output))
    path = output / 'xedit-cleaning-loot.yaml'
    assert planned['dryRun'] and not planned['written'] and not path.exists()
    written = client.call('reports.cleaning', format='loot', files=[DIRTY, QUICK, CLEAN], outputDirectory=str(output), dryRun=False)
    assert written['written'] and path.read_bytes() == report['text'].encode('utf-8')
    before = client.call('session.get_dirty_state')
    reject(client, 'reports.cleaning', format='loot', files=[DIRTY], outputDirectory=str(output), dryRun=False)
    assert path.read_bytes() == report['text'].encode('utf-8') and client.call('session.get_dirty_state') == before
    replacement = client.call('reports.cleaning', format='loot', files=[CLEAN], outputDirectory=str(output), dryRun=False, overwrite=True)
    assert replacement['written'] and path.read_bytes() == replacement['text'].encode('utf-8')
    if game == 'tes4':
        boss = client.call('reports.cleaning', format='boss', files=[DIRTY, CLEAN])
        assert 'CHECKSUM("' + DIRTY + '", ' in boss['text'] and '1 ITM, 1 UDR' in boss['text']
        assert boss['files'][1]['text'] == ''
    else: reject(client, 'reports.cleaning', format='boss', files=[DIRTY])
    reject(client, 'reports.cleaning', format='loot', files=[DIRTY, DIRTY])
    reject(client, 'reports.cleaning', format='loot', files=[])
    reject(client, 'reports.cleaning', format='loot', files=[False])
    reject(client, 'reports.cleaning', format='loot', files=[DIRTY] * 9)
    reject(client, 'reports.cleaning', format='invalid', files=[DIRTY])
    # Dirty current-state data must never be paired with the old on-disk CRC.
    sig = 'GLOB' if game == 'tes4' else 'KYWD'
    item = client.call('records.list', file=DIRTY, signature=sig)['records'][0]['locator']
    client.call('elements.set_value', **{**item, 'path': 'EDID', 'value': 'ReportModified'})
    revision = client.call('session.get_dirty_state')['mutationRevision']
    reject(client, 'reports.cleaning', format='loot', files=[DIRTY])
    assert client.call('session.get_dirty_state')['mutationRevision'] == revision
    client.call('session.save', files=[DIRTY])
    pending = client.call('session.get_dirty_state')
    if pending['pendingShutdownCount']:
        reject(client, 'reports.cleaning', format='loot', files=[DIRTY])
    client.call('session.flush')

def main():
    p = argparse.ArgumentParser(__doc__)
    p.add_argument('phase', choices=('generate', 'exercise', 'verify'))
    p.add_argument('--game', choices=('fo4', 'tes4'), default='fo4')
    p.add_argument('--overlay', type=Path, required=True); p.add_argument('--output', type=Path)
    p.add_argument('--exe', type=Path); p.add_argument('--pid', type=int); p.add_argument('--artifacts', type=Path)
    a = p.parse_args()
    if a.phase == 'generate':
        a.overlay.mkdir(parents=True, exist_ok=True)
        generated = fixtures(a.game)
        paths = [a.overlay / name for name in (*generated, 'plugins.txt')]
        if any(path.exists() for path in paths): p.error('Refusing to replace existing fixtures; choose a fresh overlay')
        for name, data in generated.items(): (a.overlay / name).write_bytes(data)
        master = 'Oblivion.esm' if a.game == 'tes4' else 'Fallout4.esm'
        (a.overlay / 'plugins.txt').write_text('\n'.join((master, BASE, DIRTY, QUICK, CLEAN)) + '\n')
    else:
        if not all((a.exe, a.pid, a.artifacts)): p.error('Live phases require exe/pid/artifacts')
        client = Client(a.exe, a.pid, a.artifacts)
        if a.phase == 'verify':
            # DIRTY was intentionally edited/saved by exercise. Confirm the new
            # disk snapshot and classification agree after a fresh process load.
            result = client.call('reports.cleaning', format='loot', files=[DIRTY, QUICK, CLEAN])
            assert [row['file'] for row in result['files']] == [DIRTY, QUICK, CLEAN]
            assert [row['counts'] for row in result['files']] == [{'itm': 0, 'udr': 1, 'nav': int(a.game == 'fo4')}, {'itm': 1, 'udr': 1, 'nav': 0}, {'itm': 0, 'udr': 0, 'nav': 0}]
            sig = 'GLOB' if a.game == 'tes4' else 'KYWD'
            item = client.call('records.list', file=DIRTY, signature=sig)['records'][0]['locator']
            assert client.call('elements.get_value', **{**item, 'path': 'EDID'})['values']['editValue'] == 'ReportModified'
            assert b'ReportModified\0' in (a.overlay / DIRTY).read_bytes()
            for row in result['files']: assert row['crc32'] == f'{zlib.crc32((a.overlay / row["file"]).read_bytes()):08X}'
        else:
            if not a.output or not a.output.is_dir(): p.error('exercise requires an existing fresh --output directory')
            exercise(client, a.overlay, a.output, a.game)

if __name__ == '__main__': main()
