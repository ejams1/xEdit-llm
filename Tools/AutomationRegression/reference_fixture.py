"""Reference-index progress/readback over a fresh row_fixture.py FO4 overlay."""
import argparse
from pathlib import Path
from itm_fixture import Client
from row_fixture import TARGET, discover, children, at


def rebuild(client, **scope):
    job = client.call('jobs.start', kind='analysis.build_references', dryRun=False, target=scope)
    polls = 0
    while not job['terminal']:
        job = client.call('jobs.get', jobId=job['jobId'])
        polls += 1
        assert polls < 1000
    assert job['state'] == 'succeeded' and job['summary']['selectedScopeComplete'], job
    client.call('jobs.discard', jobId=job['jobId'])
    return job


def referring_names(client, locator):
    result = client.call('records.referenced_by', **locator)
    assert result['complete'] and not result['incomplete'], result
    return {row['object']['editorId'] for row in result['hits']}


def exercise(client):
    ids = discover(client, TARGET)
    before = client.call('session.get_dirty_state')
    plan = client.call('jobs.start', kind='analysis.build_references', target={'allLoaded': True})
    assert plan['dryRun'], plan
    client.call('jobs.cancel', jobId=plan['jobId'])
    client.call('jobs.discard', jobId=plan['jobId'])
    scoped = rebuild(client, files=[TARGET])
    assert scoped['summary']['indexedFiles'] == 1
    full = rebuild(client, allLoaded=True)
    assert full['result']['status']['allLoadedCurrent'], full
    assert referring_names(client, ids['RowLocal0']) == {'RowListA', 'RowListB', 'RowKeywords'}
    assert client.call('session.get_dirty_state')['mutationRevision'] == before['mutationRevision']
    # Move one real link, independently observe reverse edges, then restore it.
    leaf = children(client, at(ids['RowListB'], 'FormIDs'))[0]
    old = client.call('elements.get_value', **leaf)['values']['editValue']
    client.call('elements.set_value', **{**leaf, 'value': ids['RowLocal1']['formId']})
    rebuild(client, allLoaded=True)
    assert referring_names(client, ids['RowLocal0']) == {'RowListA', 'RowKeywords'}
    assert referring_names(client, ids['RowLocal1']) == {'RowListA', 'RowListB', 'RowKeywords'}
    client.call('elements.set_value', **{**leaf, 'value': old})
    rebuild(client, allLoaded=True)
    assert referring_names(client, ids['RowLocal0']) == {'RowListA', 'RowListB', 'RowKeywords'}
    # Indexing adds no plugin edits; restoration still leaves deliberate setter dirtiness.
    revision = client.call('session.get_dirty_state')['mutationRevision']
    rebuild(client, allLoaded=True)
    assert client.call('session.get_dirty_state')['mutationRevision'] == revision


def main():
    p = argparse.ArgumentParser(__doc__)
    p.add_argument('--exe', type=Path, required=True)
    p.add_argument('--pid', type=int, required=True)
    p.add_argument('--artifacts', type=Path, required=True)
    a = p.parse_args()
    exercise(Client(a.exe, a.pid, a.artifacts))


if __name__ == '__main__': main()
