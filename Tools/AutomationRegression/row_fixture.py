"""FO4 multi-row replacement/append/removal; explicit save and fresh reload checks."""
import argparse
from collections import Counter
import json
from pathlib import Path
import struct
import zlib

from itm_fixture import Client, record, subrecord

BASE = 'AutomationRowDependencies.esm'
SOURCE = 'AutomationRowSource.esm'
TARGET = 'AutomationRowTargets.esp'
DESCRIPTION = '  Exact copied description\n '
TITLE = 'Copied row title'


def group(signature, rows):
    return struct.pack('<4sI4sIHHHH', b'GRUP', 24 + len(rows), signature, 0, 0, 0, 0, 0) + rows


def plugin(masters, groups, count, esm=False):
    body = subrecord(b'HEDR', struct.pack('<fII', 1.0, count, 0x900))
    for master in masters:
        body += subrecord(b'MAST', master.encode() + b'\0') + subrecord(b'DATA', b'\0' * 8)
    return record(b'TES4', body, int(esm)) + b''.join(groups)


def keyword(name, identity):
    return record(b'KYWD', subrecord(b'EDID', name.encode() + b'\0'), form_id=identity)


def message(name, identity, description, title, flags=0, time=2):
    body = subrecord(b'EDID', name.encode() + b'\0')
    body += subrecord(b'DESC', description.encode() + b'\0')
    body += subrecord(b'FULL', title.encode() + b'\0')
    for sig, value in ((b'INAM', 0), (b'DNAM', flags)):
        body += subrecord(sig, struct.pack('<I', value))
    if not flags & 1: body += subrecord(b'TNAM', struct.pack('<I', time))
    return record(b'MESG', body, form_id=identity)


def form_list(name, identity, references):
    body = subrecord(b'EDID', name.encode() + b'\0')
    body += b''.join(subrecord(b'LNAM', struct.pack('<I', value)) for value in references)
    return record(b'FLST', body, form_id=identity)


def misc(name, identity, references):
    body = subrecord(b'EDID', name.encode() + b'\0') + subrecord(b'OBND', b'\0' * 12)
    body += subrecord(b'KSIZ', struct.pack('<I', len(references)))
    body += subrecord(b'KWDA', struct.pack('<' + 'I' * len(references), *references))
    body += subrecord(b'DATA', struct.pack('<if', 12, 1.25))
    return record(b'MISC', body, form_id=identity)


def fixtures():
    base = group(b'KYWD', b''.join(keyword(f'RowDependency{i}', 0x01000800 + i) for i in range(4)))
    source = [group(b'MESG', message('RowSourceText', 0x02000800, DESCRIPTION, TITLE) +
                    message('RowSourceBox', 0x02000802, 'Box description', 'Box title', flags=1)),
              group(b'FLST', form_list('RowSourceList', 0x02000801, range(0x01000800, 0x01000804))),
              group(b'MISC', misc('RowSourceKeywords', 0x02000810, list(range(0x01000800, 0x01000803))))]
    targets = [group(b'KYWD', b''.join(keyword(f'RowLocal{i}', 0x01000810 + i) for i in range(4))),
               group(b'MESG', b''.join(message(f'RowText{letter}', 0x01000820 + i,
                      f'Sentinel description {letter}', f'Sentinel title {letter}') for i, letter in enumerate('AB')) +
                     message('RowPartial', 0x01000822, 'Partial sentinel description', 'Partial sentinel title', time=9)),
               group(b'FLST', form_list('RowListA', 0x01000830, range(0x01000810, 0x01000814)) +
                     form_list('RowListB', 0x01000831, [0x01000810])),
               group(b'MISC', misc('RowKeywords', 0x01000840, [0x01000812, 0x01000810, 0x01000813, 0x01000811]))]
    return {BASE: plugin(['Fallout4.esm'], [base], 4, True),
            SOURCE: plugin(['Fallout4.esm', BASE], source, 4, True),
            TARGET: plugin(['Fallout4.esm'], targets, 10)}


def disk_state(data):
    """Independent binary readback including master-relative reference ownership."""
    masters, rows = [], {}

    def visit(start, end):
        while start < end:
            sig, size, flags, identity = struct.unpack_from('<4sIII', data, start)
            if sig == b'GRUP':
                visit(start + 24, start + size)
                start += size
                continue
            body = data[start + 24:start + 24 + size]
            if flags & 0x40000:
                expected = struct.unpack_from('<I', body)[0]
                body = zlib.decompress(body[4:])
                assert len(body) == expected
            fields, pos = {}, 0
            while pos < len(body):
                sub, length = struct.unpack_from('<4sH', body, pos)
                fields.setdefault(sub, []).append(body[pos + 6:pos + 6 + length])
                pos += length + 6
            assert pos == len(body)
            if sig == b'TES4':
                masters.extend(value.rstrip(b'\0').decode() for value in fields.get(b'MAST', []))
            else:
                name = fields[b'EDID'][0].rstrip(b'\0').decode()
                rows[name] = {'signature': sig.decode(), 'identity': identity & 0xFFFFFF,
                              'flags': flags & ~0x40000, 'fields': fields}
            start += 24 + size
        assert start == end

    visit(0, len(data))
    return masters, rows


def discover(client, file):
    result = client.call('records.list', file=file, limit=100)
    assert not result['truncated'], result
    return {row['object']['editorId']: row['locator'] for row in result['records']
            if 'editorId' in row['object']}


def children(client, locator):
    result = client.call('elements.children', **locator, limit=100)
    assert not result['truncated'], result
    return [row['locator'] for row in result['children']]


def text(client, locator, path):
    return client.call('elements.get_value', **{**locator, 'path': path})['values']['editValue']


def linked_ids(client, locator):
    result = client.call('records.references', **locator, limit=100)
    assert not result['truncated'], result
    return {row['locator']['formId'].upper() for row in result['hits']}


def list_ids(client, locator, path='FormIDs'):
    # Native integer value is file-relative; LinksTo gives an unambiguous record
    # identity after AddMaster rebases the target's file-relative slots.
    values = []
    for child in children(client, {**locator, 'path': path}):
        linked = client.call('elements.edit_capabilities', **child)['reference']
        assert linked['resolved'], linked
        values.append(linked['locator']['formId'].upper())
    return values


def revision(client):
    return client.call('session.get_dirty_state')['mutationRevision']


def request(client, items, **kwargs):
    return client.call('batch.rows', items=items, expectedRevision=revision(client), **kwargs)


def reject(client, items, code=None, **kwargs):
    before = client.call('session.get_dirty_state')
    envelope = client.request(json.dumps({'command': 'batch.rows', 'args': {
        'items': items, 'expectedRevision': before['mutationRevision'], 'dryRun': False, **kwargs}}))
    assert not envelope['ok'], envelope
    if code: assert envelope['error']['code'] == code, envelope
    assert client.call('session.get_dirty_state') == before


def row(mode, target, source=None):
    return {'mode': mode, 'target': target, **({'source': source} if source else {})}


def at(locator, path):
    return {**locator, 'path': path}


def verify(client, overlay, persisted=True):
    source, target, base = (discover(client, file) for file in (SOURCE, TARGET, BASE))
    assert set(target) == {f'RowLocal{i}' for i in range(4)} | {'RowTextA', 'RowTextB', 'RowPartial', 'RowListA', 'RowListB', 'RowKeywords'}
    for name in ('RowTextA', 'RowTextB'):
        assert text(client, target[name], 'DESC') == DESCRIPTION
        assert text(client, target[name], 'TNAM') == '2'
        missing = client.request(json.dumps({'command': 'elements.get_value', 'args': at(target[name], 'FULL')}))
        assert not missing['ok'] and missing['error']['code'] == 'element_not_found', missing
    expected = {'RowListA': [base['RowDependency1']['formId'].upper(), base['RowDependency3']['formId'].upper()],
                'RowListB': [base['RowDependency1']['formId'].upper(), base['RowDependency0']['formId'].upper()]}
    for name, ids in expected.items():
        assert list_ids(client, target[name]) == ids, (name, list_ids(client, target[name]), ids)
        assert linked_ids(client, target[name]) == set(ids)
    expected_keywords = [base[f'RowDependency{i}']['formId'].upper() for i in range(3)] + [target['RowLocal3']['formId'].upper()]
    assert Counter(list_ids(client, target['RowKeywords'], r'Keywords\KWDA')) == Counter(expected_keywords)
    assert linked_ids(client, target['RowKeywords']) == set(expected_keywords)
    assert text(client, target['RowKeywords'], r'Keywords\KSIZ') == '4'
    assert text(client, target['RowKeywords'], r'DATA\Value') == '12'
    assert text(client, target['RowPartial'], 'FULL') == 'Partial sentinel title'
    assert text(client, target['RowPartial'], 'DESC') == 'Partial sentinel description'
    assert text(client, target['RowPartial'], 'TNAM') == '2'
    assert text(client, source['RowSourceText'], 'FULL') == TITLE
    assert text(client, source['RowSourceText'], 'DESC') == DESCRIPTION
    assert client.call('files.get', name=TARGET)['file']['masters'] == ['Fallout4.esm', BASE]
    for file in (BASE, SOURCE): assert (overlay / file).read_bytes() == fixtures()[file]
    # A memory-mapped save may defer final-path replacement until terminal flush.
    # Live semantics must pass now; final disk bytes are mandatory on fresh verify.
    if not persisted: return
    masters, persisted = disk_state((overlay / TARGET).read_bytes())
    assert masters == ['Fallout4.esm', BASE]
    for name, identity in (('RowTextA', 0x820), ('RowTextB', 0x821), ('RowListA', 0x830), ('RowListB', 0x831)):
        assert persisted[name]['identity'] == identity and persisted[name]['flags'] == 0
    for name in ('RowTextA', 'RowTextB'):
        assert persisted[name]['fields'][b'DESC'] == [DESCRIPTION.encode() + b'\0']
        assert b'FULL' not in persisted[name]['fields']
        assert persisted[name]['fields'][b'TNAM'] == [struct.pack('<I', 2)]
    for name, low_ids in (('RowListA', [0x801, 0x803]), ('RowListB', [0x801, 0x800])):
        raw_ids = [struct.unpack('<I', value)[0] for value in persisted[name]['fields'][b'LNAM']]
        assert raw_ids == [0x01000000 + identity for identity in low_ids], (name, raw_ids)
    keywords = persisted['RowKeywords']['fields']
    assert Counter(struct.unpack('<IIII', keywords[b'KWDA'][0])) == Counter([0x01000800, 0x01000801, 0x01000802, 0x02000813])
    assert keywords[b'KSIZ'] == [struct.pack('<I', 4)]
    assert keywords[b'DATA'] == [struct.pack('<if', 12, 1.25)]
    partial = persisted['RowPartial']['fields']
    assert partial[b'DNAM'] == [struct.pack('<I', 0)] and partial[b'TNAM'] == [struct.pack('<I', 2)]
    assert partial[b'FULL'] == [b'Partial sentinel title\0']


def exercise(client, overlay, no_consent=False):
    source, target, base = (discover(client, file) for file in (SOURCE, TARGET, BASE))
    source_text = source['RowSourceText']
    replacements = [row('replace', at(target[name], path), at(source_text, path))
                    for name in ('RowTextA', 'RowTextB') for path in ('FULL', 'DESC')]
    before = client.call('session.get_dirty_state')
    disk_before = (overlay / TARGET).read_bytes()
    plan = request(client, replacements)
    assert plan['dryRun'] and plan['complete'] and not plan['changed']
    assert [item['outcome'] for item in plan['items']] == ['planned'] * 4
    assert client.call('session.get_dirty_state') == before
    if no_consent:
        reject(client, replacements, 'consent_required')
        assert (overlay / TARGET).read_bytes() == disk_before
        return
    # Every rejection includes a valid first row to prove all-target preflight.
    first = replacements[0]
    cases = [
        [first, first],
        [first, row('replace', at(target['RowTextA'], 'Record Header'), at(source_text, 'FULL'))],
        [first, row('replace', at(target['RowTextA'], r'Record Header\Record Flags'), at(source_text, r'Record Header\Record Flags'))],
        [first, row('append', at(target['RowTextB'], 'DESC'), at(source_text, 'DESC'))],
        [first, row('replace', at(target['RowTextB'], 'Missing Row'), at(source_text, 'FULL'))],
        [first, row('replace', {'file': 'Fallout4.esm', 'formId': '00000007', 'path': 'FULL'}, at(source_text, 'FULL'))],
        [first, row('replace', at(target['RowTextB'], 'DESC'), at(target['RowTextA'], 'DESC'))],
        [first, row('replace', at(target['RowListA'], 'FormIDs'), at(source['RowSourceList'], 'FormIDs'))],
    ]
    for items in cases:
        reject(client, items)
        assert text(client, target['RowTextA'], 'FULL') == 'Sentinel title A'
        assert client.call('files.get', name=TARGET)['file']['masters'] == ['Fallout4.esm']
    reject(client, [first] * 17, 'invalid_request')
    applied = request(client, replacements, dryRun=False)
    assert applied['complete'] and applied['completed'] == 4
    assert [item['outcome'] for item in applied['items']] == ['applied'] * 4
    for name in ('RowTextA', 'RowTextB'):
        assert text(client, target[name], 'FULL') == TITLE
        assert text(client, target[name], 'DESC') == DESCRIPTION
    # Same payload replacement is valid; append repeats intentionally add rows.
    assert request(client, replacements, dryRun=False)['complete']
    # The native DNAM callback removes TNAM when Message Box is enabled. All
    # three rows exist at preflight; item one must fail as detached, and item two
    # must remain untouched, with the earlier flag change honestly retained.
    partial_target = target['RowPartial']
    partial = request(client, [
        row('replace', at(partial_target, 'DNAM'), at(source['RowSourceBox'], 'DNAM')),
        row('replace', at(partial_target, 'TNAM'), at(source_text, 'TNAM')),
        row('replace', at(partial_target, 'FULL'), at(source_text, 'FULL'))], dryRun=False)
    assert not partial['complete'] and partial['completed'] == 1, partial
    assert [item['outcome'] for item in partial['items']] == ['applied', 'failed', 'not-attempted'], partial
    assert partial['failure']['code'] == 'state_conflict' and partial['failure']['index'] == 1, partial
    assert partial['failure']['details']['partial'] and partial['changed'], partial
    flags = client.call('elements.get_value', **at(partial_target, 'DNAM'))['values']['nativeValue']['value']
    assert int(flags) == 1
    missing = client.request(json.dumps({'command': 'elements.get_value', 'args': at(partial_target, 'TNAM')}))
    assert not missing['ok'] and missing['error']['code'] == 'element_not_found', missing
    assert text(client, partial_target, 'FULL') == 'Partial sentinel title'
    # Recover through an explicit fresh batch; the callback recreates TNAM at 2.
    assert request(client, [row('replace', at(partial_target, 'DNAM'), at(source_text, 'DNAM'))], dryRun=False)['complete']
    source_array = at(source['RowSourceList'], 'FormIDs')
    source_rows = children(client, source_array)
    array_target = at(target['RowListA'], 'FormIDs')
    reject(client, [row('remove', array_target), row('remove', children(client, array_target)[0])])
    reject(client, [row('replace', array_target, source_rows[0])])
    bulk = request(client, [row('replace', array_target, source_array)], addRequiredMasters=True, dryRun=False)
    assert bulk['complete'] and bulk['completed'] == 1, bulk
    assert bulk['items'][0]['addedMasters'] == [BASE], bulk
    assert list_ids(client, target['RowListA']) == [base[f'RowDependency{i}']['formId'].upper() for i in range(4)]
    # Remove indices 0 and 2 in one batch. Re-resolving the second old path after
    # removal would wrongly remove index 3; pinned native identity must retain it.
    rows = children(client, array_target)
    removed = request(client, [row('remove', rows[0]), row('remove', rows[2])], dryRun=False)
    assert removed['complete'] and removed['completed'] == 2, removed
    appended = request(client, [row('append', at(target['RowListB'], 'FormIDs'), source_rows[0])], dryRun=False)
    assert appended['complete'], appended
    current = children(client, at(target['RowListB'], 'FormIDs'))
    changed = request(client, [row('replace', current[0], source_rows[1])], dryRun=False)
    assert changed['complete'], changed
    keyword_target = at(target['RowKeywords'], r'Keywords\KWDA')
    keyword_source = children(client, at(source['RowSourceKeywords'], r'Keywords\KWDA'))
    def linked_row(rows, identity):
        return next(loc for loc in rows if client.call('elements.edit_capabilities', **loc)['reference']['locator']['formId'].upper() == identity.upper())
    current = children(client, keyword_target)
    # Replacing a sorted key may reorder KWDA. The second selected native row
    # must remain the intended local keyword, independent of its old index.
    replacements = [row('replace', linked_row(current, target[f'RowLocal{i}']['formId']),
                        linked_row(keyword_source, base[f'RowDependency{i}']['formId'])) for i in range(2)]
    assert request(client, replacements, dryRun=False)['complete']
    current = children(client, keyword_target)
    assert request(client, [row('remove', linked_row(current, target['RowLocal2']['formId']))], dryRun=False)['complete']
    assert request(client, [row('append', keyword_target, linked_row(keyword_source, base['RowDependency2']['formId']))], dryRun=False)['complete']
    assert request(client, [row('remove', at(target[name], 'FULL')) for name in ('RowTextA', 'RowTextB')], dryRun=False)['complete']
    stale = client.request(json.dumps({'command': 'batch.rows', 'args': {
        'expectedRevision': before['mutationRevision'], 'items': replacements, 'dryRun': False}}))
    assert not stale['ok'] and stale['error']['code'] == 'stale_revision', stale
    assert (overlay / TARGET).read_bytes() == disk_before
    for file in (BASE, SOURCE): assert (overlay / file).read_bytes() == fixtures()[file]
    client.call('session.save', files=[TARGET])
    verify(client, overlay, persisted=False)
    client.call('session.flush')


def main():
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument('phase', choices=('generate', 'exercise', 'no-consent', 'verify'))
    parser.add_argument('--overlay', type=Path, required=True)
    parser.add_argument('--exe', type=Path)
    parser.add_argument('--pid', type=int)
    parser.add_argument('--artifacts', type=Path)
    args = parser.parse_args()
    if args.phase == 'generate':
        args.overlay.mkdir(parents=True, exist_ok=True)
        files = fixtures()
        paths = [args.overlay / file for file in files] + [args.overlay / 'plugins.txt']
        if any(path.exists() for path in paths): parser.error('Use a fresh overlay; refusing fixture overwrite')
        for name, data in files.items(): (args.overlay / name).write_bytes(data)
        (args.overlay / 'plugins.txt').write_text('\n'.join(['Fallout4.esm', *files]) + '\n', encoding='utf-8')
    else:
        if args.exe is None or args.pid is None or args.artifacts is None:
            parser.error('Live phases require --exe, --pid and --artifacts')
        client = Client(args.exe, args.pid, args.artifacts)
        if args.phase == 'verify': verify(client, args.overlay)
        else: exercise(client, args.overlay, args.phase == 'no-consent')


if __name__ == '__main__': main()
