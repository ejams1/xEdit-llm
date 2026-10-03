"""Read-only FO4 comparison acceptance using fresh row_fixture.py plugins."""
import argparse
import json
from pathlib import Path

from itm_fixture import Client
from row_fixture import BASE, SOURCE, TARGET, DESCRIPTION, discover, fixtures


def exercise(client, overlay, input_path):
    source, targets = discover(client, SOURCE), discover(client, TARGET)
    before = client.call('session.get_dirty_state')
    disk_before = {name: (overlay / name).read_bytes() for name in fixtures()}
    selected = [targets['RowTextB'], source['RowSourceText'], targets['RowTextA']]
    result = client.call('comparisons.records', records=selected, path='DESC')
    assert result['complete'] and len(result['rows']) == 1, result
    assert [col['record']['formId'] for col in result['columns']] == [loc['formId'] for loc in selected]
    cells = result['rows'][0]['cells']
    assert all(cell['state'] == 'present' and cell['present'] for cell in cells), result
    assert [cell['values']['editValue'] for cell in cells] == [
        'Sentinel description B', DESCRIPTION, 'Sentinel description A'], result
    reverse = client.call('comparisons.records', records=selected[::-1], path='DESC')
    assert [cell['values']['editValue'] for cell in reverse['rows'][0]['cells']] == [
        'Sentinel description A', DESCRIPTION, 'Sentinel description B']
    missing = client.call('comparisons.records', records=[source['RowSourceBox'], targets['RowTextA']], path='TNAM')
    assert not missing['columns'][0]['scopePresent'] and missing['columns'][1]['scopePresent'], missing
    assert missing['rows'][0]['cells'][0]['state'] == 'missing', missing
    limited = client.call('comparisons.records', records=selected, rowLimit=1)
    assert not limited['complete'] and limited['incompleteReason'] == 'row-limit', limited
    for records in ([selected[0], selected[0]], [selected[0], source['RowSourceList']]):
        response = client.request(json.dumps({'command': 'comparisons.records', 'args': {'records': records}}))
        assert not response['ok'], response
    assert client.call('session.get_dirty_state') == before
    args = dict(sourceFile=SOURCE, inputPath=str(input_path.resolve()), fileName='AutomationReadOnlyCompare.esp')
    plan = client.call('comparisons.load', **args)
    assert plan['dryRun'] and not plan['loaded'], plan
    assert client.call('session.get_dirty_state') == before
    input_before = input_path.read_bytes()
    loaded = client.call('comparisons.load', **args, dryRun=False)
    assert loaded['loaded'] and not loaded['editable'] and 'failure' not in loaded, loaded
    assert not (overlay / args['fileName']).exists()
    comparison = discover(client, args['fileName'])
    pair = client.call('comparisons.records', records=[source['RowSourceText'], comparison['RowSourceText']], path='DESC')
    assert [cell['values']['editValue'] for cell in pair['rows'][0]['cells']] == [DESCRIPTION, DESCRIPTION], pair
    denied = client.request(json.dumps({'command': 'elements.set_value', 'args': {
        **comparison['RowSourceText'], 'path': 'DESC', 'value': 'must not write'}}))
    assert not denied['ok'], denied
    assert input_path.read_bytes() == input_before
    for name, data in disk_before.items(): assert (overlay / name).read_bytes() == data
    # Read-only comparison cannot be saved; ordinary plugins remain clean.
    assert client.call('session.get_dirty_state')['mutationRevision'] == before['mutationRevision']


def main():
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument('--overlay', type=Path, required=True)
    parser.add_argument('--input-path', type=Path, required=True)
    parser.add_argument('--exe', type=Path, required=True)
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--artifacts', type=Path, required=True)
    args = parser.parse_args()
    exercise(Client(args.exe, args.pid, args.artifacts), args.overlay, args.input_path)


if __name__ == '__main__': main()
