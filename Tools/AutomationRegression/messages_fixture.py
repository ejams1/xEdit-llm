"""Session message cursor/export and native log attribution acceptance."""
import argparse
import json
from pathlib import Path
from itm_fixture import Client


def read(client, cursor=None):
    rows, epoch = [], None
    for _ in range(1000):
        page = client.call('messages.read', limit=13, **({'cursor': cursor} if cursor else {}))
        assert epoch is None or epoch == page['epoch']
        epoch = page['epoch']; rows += page['messages']; cursor = page.get('nextCursor')
        if not cursor:
            assert page['complete']
            assert [int(row['sequence']) for row in rows] == sorted(set(int(row['sequence']) for row in rows))
            return rows
    raise AssertionError('Message cursor did not terminate')


def exercise(client, output, format=None, locator=None):
    before = client.call('session.get_dirty_state')
    rows = read(client)
    assert rows, 'Fresh loaded daemon should have startup messages'
    plan = client.call('messages.export', outputDirectory=str(output.resolve()))
    assert plan['dryRun'] and not plan['written']
    saved = client.call('messages.export', outputDirectory=str(output.resolve()), dryRun=False)
    assert saved['written']
    exported = Path(saved['outputPath']).read_text(encoding='utf-8')
    latest = read(client, saved['epoch'] + '|' + saved['firstSequence'] + '|' + saved['snapshotEnd'])
    assert exported == ''.join(row['text'] + '\n' for row in latest), (exported, latest)
    exists = client.request(json.dumps({'command': 'messages.export', 'args': {
        'outputDirectory': str(output.resolve()), 'dryRun': False}}))
    assert not exists['ok'], exists
    if format:
        fid = locator['formId'].upper()
        if format == 'papyrus':
            timestamp = '[10/03/2026 - 10:00:00AM] '
            assert len(timestamp) == 26
            text = timestamp + f'error: Fixture ({fid})\n' + timestamp + f'warning: Fixture ({fid})\n'
        else:
            text = fid + '\tabcdefgh1.5 extra\n' + fid + '\tabcdefgh2.0 extra\n'
        path = output / 'native-fixture.log'; path.write_text(text, encoding='utf-8')
        result = client.call('logs.analyze', inputDirectory=str(output.resolve()), fileName=path.name, format=format)
        assert result['complete'] and result['unknownFormIDs'] == 0 and result['attributedRecords'] == 1, result
        row = result['records'][0]
        assert row['formId'].upper() == fid and row['file'] == locator['file'], row
        if format == 'papyrus': assert row['errors'] == row['warnings'] == 1, row
        else: assert row['executions'] == 2 and row['totalMs'] == 3.5 and row['maxMs'] == 2, row
    assert client.call('session.get_dirty_state') == before


def main():
    p = argparse.ArgumentParser(__doc__)
    p.add_argument('--exe', type=Path, required=True); p.add_argument('--pid', type=int, required=True)
    p.add_argument('--artifacts', type=Path, required=True); p.add_argument('--output', type=Path, required=True)
    p.add_argument('--format', choices=('papyrus', 'xse-profiler')); p.add_argument('--file'); p.add_argument('--form-id')
    a = p.parse_args()
    if a.format and not (a.file and a.form_id): p.error('Native parser checks require a real loaded --file and --form-id')
    exercise(Client(a.exe, a.pid, a.artifacts), a.output, a.format, {'file': a.file, 'formId': a.form_id})


if __name__ == '__main__': main()
