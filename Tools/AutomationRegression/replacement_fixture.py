"""FO4 whole-record Assign identity, full values, dependency rebasing and persistence.

Generate into a fresh MO2 overlay; caller owns launch and fresh-process restart.
Python checks alone do not execute or validate the native replacement route.
"""
import argparse
import json
from pathlib import Path
import struct

from itm_fixture import Client
from row_fixture import (BASE, SOURCE, TARGET, fixtures as row_fixtures, group,
                         message, disk_state, discover, text, list_ids,
                         linked_ids, revision)

DESCRIPTION = '  Full modal value\n' + ' spaced line \n' * 600 + ' trailing space '
TITLE = 'Whole record title'


def record_headers(data):
    """Independent serialized header reader; no daemon summaries or preview text."""
    rows = {}

    def visit(start, end):
        while start < end:
            sig, size, flags, identity, vcs1, version, vcs2 = struct.unpack_from('<4sIIIIHH', data, start)
            if sig == b'GRUP':
                visit(start + 24, start + size)
                start += size
                continue
            if sig != b'TES4':
                rows[identity & 0xFFFFFF] = (identity, flags, vcs1, version, vcs2)
            start += 24 + size
        assert start == end

    visit(0, len(data))
    return rows


def fixtures():
    files = row_fixtures()
    # A flags/version/VCS difference makes preserving target identity versus
    # copying a whole source header observable in the independent saved bytes.
    original = message('RowSourceText', 0x02000800, DESCRIPTION, TITLE)
    original = original[:8] + struct.pack('<IIIHH', 0x80000000, 0x02000800, 0x11223344, 130, 0x1234) + original[24:]
    source = files[SOURCE]
    start = source.index(b'GRUP')
    size = struct.unpack_from('<I', source, start + 4)[0]
    files[SOURCE] = source[:start] + group(b'MESG', original +
        message('RowSourceBox', 0x02000802, 'Box description', 'Box title', flags=1)) + source[start + size:]
    old_numeric = struct.pack('<if', 12, 1.25)
    assert files[TARGET].count(old_numeric) == 1
    files[TARGET] = files[TARGET].replace(old_numeric, struct.pack('<if', 23, 2.75))
    return files


def replace(client, source, target, **args):
    return client.call('records.replace', source=source, target=target,
                       expectedRevision=revision(client), **args)


def reject(client, source, target, code=None, **args):
    before = client.call('session.get_dirty_state')
    envelope = client.request(json.dumps({'command': 'records.replace', 'args': {
        'source': source, 'target': target, 'expectedRevision': before['mutationRevision'],
        'dryRun': False, **args}}))
    assert not envelope['ok'], envelope
    if code: assert envelope['error']['code'] == code, envelope
    assert client.call('session.get_dirty_state') == before


def verify(client, overlay, persisted=True):
    target, base = (discover(client, file) for file in (TARGET, BASE))
    assert target['RowSourceText']['formId'][-6:].upper() == '000820'
    assert text(client, target['RowSourceText'], 'DESC') == DESCRIPTION
    assert text(client, target['RowSourceText'], 'FULL') == TITLE
    assert text(client, target['RowSourceBox'], 'DESC') == 'Box description'
    absent = client.request(json.dumps({'command': 'elements.get_value', 'args': {
        **target['RowSourceBox'], 'path': 'TNAM'}}))
    assert not absent['ok'] and absent['error']['code'] == 'element_not_found', absent
    expected_ids = [base[f'RowDependency{i}']['formId'].upper() for i in range(4)]
    assert list_ids(client, target['RowSourceList']) == expected_ids
    assert linked_ids(client, target['RowSourceList']) == set(expected_ids)
    keywords = target['RowSourceKeywords']
    assert list_ids(client, keywords, r'Keywords\KWDA') == expected_ids[:3]
    assert text(client, keywords, r'Keywords\KSIZ') == '3'
    assert text(client, keywords, r'DATA\Value') == '12'
    assert float(text(client, keywords, r'DATA\Weight')) == 1.25
    for file in (BASE, SOURCE): assert (overlay / file).read_bytes() == fixtures()[file]
    if not persisted: return
    masters, rows = disk_state((overlay / TARGET).read_bytes())
    assert masters == ['Fallout4.esm', BASE]
    expected = {'RowSourceText': 0x820, 'RowSourceBox': 0x822,
                'RowSourceList': 0x831, 'RowSourceKeywords': 0x840}
    _, source_rows = disk_state(fixtures()[SOURCE])
    for name, identity in expected.items():
        assert rows[name]['identity'] == identity
        assert rows[name]['fields'] == source_rows[name]['fields'], (name, rows[name], source_rows[name])
    # The target's self slot rebases when BASE is added; its load-order identity
    # is stable, and neither the source FormID nor its VCS bytes may leak through.
    headers = record_headers((overlay / TARGET).read_bytes())
    assert headers[0x820] == (0x02000820, 0x80000000, 0, 130, 0), headers[0x820]
    for identity in (0x822, 0x831, 0x840):
        assert headers[identity] == (0x02000000 + identity, 0, 0, 131, 0), headers[identity]
    initial_rows = disk_state(fixtures()[TARGET])[1]
    # Unselected local FLST links must rebase too when the target self slot moves.
    initial_rows['RowListA']['fields'][b'LNAM'] = [struct.pack('<I', 0x02000810 + i) for i in range(4)]
    for name in initial_rows.keys() - {'RowTextA', 'RowPartial', 'RowListB', 'RowKeywords'}:
        assert rows[name] == initial_rows[name], (name, rows[name], initial_rows[name])
    assert not client.call('session.get_dirty_state')['dirty']


def exercise(client, overlay, no_consent=False, excluded_source=None):
    source, target = (discover(client, file) for file in (SOURCE, TARGET))
    src, dst = source['RowSourceText'], target['RowTextA']
    before = client.call('session.get_dirty_state')
    plan = replace(client, src, dst)
    assert plan['dryRun'] and plan['complete'] and not plan['changed'], plan
    assert plan['before']['formId'] == dst['formId'] and plan['source']['formId'] == src['formId']
    descriptions = [n['values']['editValue'] for n in plan['sourcePayload']['nodes']
                    if n.get('values', {}).get('editValue') == DESCRIPTION]
    assert descriptions == [DESCRIPTION], descriptions
    assert client.call('session.get_dirty_state') == before
    if no_consent:
        reject(client, src, dst, 'consent_required')
        return
    reject(client, src, dst, 'stale_revision', expectedRevision='0')
    reject(client, src, src, 'invalid_request')
    reject(client, src, {**dst, 'path': 'Record Header'}, 'invalid_request')
    reject(client, src, target['RowListB'], 'invalid_target')
    reject(client, source['RowSourceList'], target['RowListB'], 'mutation_not_allowed')
    if excluded_source:
        excluded = discover(client, excluded_source)
        reject(client, next(iter(excluded.values())), dst, 'unsupported_replacement_scope')
    assert text(client, dst, 'DESC') == 'Sentinel description A'
    planned = replace(client, source['RowSourceList'], target['RowListB'], addRequiredMasters=True)
    assert planned['masterPlan']['planned'] == [BASE] and not planned['changed'], planned
    for source_name, target_name in [('RowSourceText', 'RowTextA'), ('RowSourceBox', 'RowPartial'),
                                     ('RowSourceList', 'RowListB'), ('RowSourceKeywords', 'RowKeywords')]:
        applied = replace(client, source[source_name], target[target_name], addRequiredMasters=True, dryRun=False)
        assert applied['complete'] and applied['outcome'] == 'applied', applied
        assert all(applied[key] for key in ('assignCalled', 'identityPreserved', 'headerMatchesPolicy', 'payloadMatchesSource')), applied
        assert applied['after']['formId'] == target[target_name]['formId'], applied
    again = replace(client, src, dst, dryRun=False)
    assert again['complete'] and again['payloadMatchesSource'], again
    assert (overlay / TARGET).read_bytes() == fixtures()[TARGET]
    client.call('session.save', files=[TARGET])
    verify(client, overlay, persisted=False)
    client.call('session.flush')


def main():
    p = argparse.ArgumentParser(__doc__)
    p.add_argument('phase', choices=('generate', 'exercise', 'no-consent', 'verify', 'unsupported-mode'))
    p.add_argument('--overlay', type=Path, required=True)
    p.add_argument('--exe', type=Path); p.add_argument('--pid', type=int); p.add_argument('--artifacts', type=Path)
    p.add_argument('--excluded-source-file', help='Loaded comparison-only plugin or localized fixture')
    a = p.parse_args()
    if a.phase == 'generate':
        files = fixtures(); a.overlay.mkdir(parents=True, exist_ok=True)
        if any((a.overlay / name).exists() for name in [*files, 'plugins.txt']): p.error('Use a fresh overlay')
        for name, data in files.items(): (a.overlay / name).write_bytes(data)
        (a.overlay / 'plugins.txt').write_text('\n'.join(['Fallout4.esm', *files]) + '\n', encoding='utf-8')
        return
    if a.exe is None or a.pid is None or a.artifacts is None: p.error('Live phases require --exe, --pid and --artifacts')
    client = Client(a.exe, a.pid, a.artifacts)
    if a.phase == 'verify': verify(client, a.overlay)
    elif a.phase == 'unsupported-mode':
        before = client.call('session.get_dirty_state')
        envelope = client.request(json.dumps({'command': 'records.replace', 'args': {}}))
        assert not envelope['ok'] and envelope['error']['code'] == 'unsupported_game_mode', envelope
        assert client.call('session.get_dirty_state') == before
    else: exercise(client, a.overlay, a.phase == 'no-consent', a.excluded_source_file)


if __name__ == '__main__': main()
