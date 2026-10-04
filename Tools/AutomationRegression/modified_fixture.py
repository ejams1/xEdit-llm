"""Explicit filter-selection marking and header-only ONAM exclusion; save/readback."""
import argparse
import json
from pathlib import Path
from itm_fixture import Client
from row_fixture import TARGET, fixtures, disk_state


def verify(client, overlay):
    expected = disk_state(fixtures()[TARGET])
    observed = disk_state((overlay / TARGET).read_bytes())
    assert observed == expected, (observed, expected)
    assert not client.call('session.get_dirty_state')['dirty']


def exercise(client, overlay, onam_file=None):
    before = client.call('session.get_dirty_state')
    page = client.call('records.apply_filter', files=[TARGET], editorIdContains='RowText')
    assert page['complete'] and page['count'] == 2, page
    targets = [row['locator'] for row in page['hits']]
    plan = client.call('records.mark_modified', records=targets, expectedRevision=page['revision'])
    assert plan['dryRun'] and not plan['changed'] and plan['complete'], plan
    assert client.call('session.get_dirty_state')['mutationRevision'] == before['mutationRevision']
    bad = client.request(json.dumps({'command': 'records.mark_modified', 'args': {
        'records': targets, 'expectedRevision': '0', 'dryRun': False}}))
    assert not bad['ok'] and bad['error']['code'] == 'stale_revision', bad
    files = [TARGET] + ([onam_file] if onam_file else [])
    header = client.call('files.mark_without_onam', files=files, dryRun=False)
    assert header['complete'] and header['files'][0]['outcome'] == 'called', header
    assert header['files'][0]['modifiedAfter'], header
    if onam_file: assert header['files'][1]['hasONAM'] and header['files'][1]['outcome'] == 'skipped-onam', header
    marked = client.call('records.mark_modified', records=targets, dryRun=False)
    assert marked['complete'] and all(row['modifiedAfter'] and row['outcome'] == 'called' for row in marked['records']), marked
    again = client.call('records.mark_modified', records=targets, dryRun=False)
    assert again['complete'] and all(row['modifiedBefore'] and row['modifiedAfter'] for row in again['records']), again
    assert disk_state((overlay / TARGET).read_bytes()) == disk_state(fixtures()[TARGET])
    client.call('session.save', files=[TARGET]); client.call('session.flush')


def main():
    p = argparse.ArgumentParser(__doc__)
    p.add_argument('phase', choices=('exercise', 'verify'))
    p.add_argument('--overlay', type=Path, required=True); p.add_argument('--onam-file')
    p.add_argument('--exe', type=Path, required=True); p.add_argument('--pid', type=int, required=True)
    p.add_argument('--artifacts', type=Path, required=True)
    a = p.parse_args(); client = Client(a.exe, a.pid, a.artifacts)
    if a.phase == 'verify': verify(client, a.overlay)
    else: exercise(client, a.overlay, a.onam_file)


if __name__ == '__main__': main()
