"""Explicit master addition on fresh row_fixture.py FO4 plugins; save/reload readback."""
import argparse
import json
from pathlib import Path
from itm_fixture import Client
from row_fixture import BASE, SOURCE, TARGET, discover, disk_state


def verify(client, overlay, expected_locators):
    assert client.call('files.get', name=TARGET)['file']['masters'] == ['Fallout4.esm', BASE, SOURCE]
    observed = discover(client, TARGET)
    assert observed == expected_locators, (observed, expected_locators)
    data = disk_state((overlay / TARGET).read_bytes())
    assert data[0] == ['Fallout4.esm', BASE, SOURCE], data
    assert data[1]['RowTextA']['fields'][b'DESC'] == [b'Sentinel description A\0']
    links = client.call('records.references', **observed['RowKeywords'])
    assert links['complete'] and len(links['hits']) == 4, links
    assert all(row['locator']['file'] == TARGET for row in links['hits']), links


def exercise(client, overlay, state):
    before = client.call('session.get_dirty_state')
    ids = discover(client, TARGET)
    disk_before = (overlay / TARGET).read_bytes()
    plan = client.call('files.add_masters', targetFile=TARGET, masters=[SOURCE, BASE])
    assert plan['dryRun'] and plan['planned'] == [BASE, SOURCE] and not plan['changed'], plan
    for target, names in ((TARGET, [BASE, TARGET]), (TARGET, [BASE, 'MissingMaster.esm']),
                          (TARGET, [BASE, BASE]), (BASE, [SOURCE]), (TARGET, [])):
        response = client.request(json.dumps({'command': 'files.add_masters', 'args': {
            'targetFile': target, 'masters': names, 'dryRun': False}}))
        assert not response['ok'], response
    assert client.call('session.get_dirty_state')['mutationRevision'] == before['mutationRevision']
    result = client.call('files.add_masters', targetFile=TARGET, masters=[SOURCE, BASE], dryRun=False)
    assert result['complete'] and result['added'] == [BASE, SOURCE] and result['requiresSave'], result
    assert discover(client, TARGET) == ids
    no_op = client.call('files.add_masters', targetFile=TARGET, masters=[BASE, SOURCE], dryRun=False)
    assert no_op['complete'] and not no_op['changed'] and not no_op['added'], no_op
    assert (overlay / TARGET).read_bytes() == disk_before
    state.write_text(json.dumps(ids), encoding='utf-8')
    client.call('session.save', files=[TARGET])
    client.call('session.flush')


def main():
    p = argparse.ArgumentParser(__doc__)
    p.add_argument('phase', choices=('exercise', 'verify'))
    p.add_argument('--overlay', type=Path, required=True)
    p.add_argument('--state', type=Path, required=True)
    p.add_argument('--exe', type=Path, required=True)
    p.add_argument('--pid', type=int, required=True)
    p.add_argument('--artifacts', type=Path, required=True)
    a = p.parse_args()
    client = Client(a.exe, a.pid, a.artifacts)
    if a.phase == 'exercise': exercise(client, a.overlay, a.state)
    else: verify(client, a.overlay, json.loads(a.state.read_text(encoding='utf-8')))


if __name__ == '__main__': main()
