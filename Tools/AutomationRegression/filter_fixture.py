"""Native filter acceptance over existing row/reachability/VWD fixture overlays.

Run each scene in a fresh daemon. This runner never saves or changes plugins.
"""
import argparse
import json
from pathlib import Path

from itm_fixture import Client
from row_fixture import SOURCE, TARGET, DESCRIPTION


def query(client, **args):
    rows, cursor = [], None
    for _ in range(10000):
        page = client.call('records.apply_filter', **args, **({'cursor': cursor} if cursor else {}))
        assert not page['guiFilterChanged'] and not page['incomplete'], page
        rows += page['hits']
        cursor = page.get('nextCursor')
        if not cursor:
            assert page['complete'], page
            return {row['object']['editorId'] for row in rows}
    raise AssertionError('Filter did not terminate')


def rejected(client, **args):
    response = client.request(json.dumps({'command': 'records.apply_filter', 'args': args}))
    assert not response['ok'], response


def exercise(client, scene):
    before = client.call('session.get_dirty_state')
    options = client.call('records.filter_options')
    assert options['presets']['conflicts']['conflictThis'] == [
        'ctIdenticalToMasterWinsConflict', 'ctConflictWins', 'ctConflictLoses']
    assert options['unsupported'] and options['predicates'], options
    if scene == 'rows':
        assert query(client, files=[SOURCE], editorIdContains='sourcel') == {'RowSourceList'}
        assert query(client, files=[SOURCE], elementValueContains=DESCRIPTION.lower()) == {'RowSourceText'}
        assert query(client, files=[TARGET], displayNameContains='Sentinel title', signatures=['MESG']) == {'RowTextA', 'RowTextB'}
        assert query(client, files=[SOURCE], isPersistent=False) == set()
        assert query(client, files=[SOURCE], hasVWDMesh=False) == set()
        assert query(client, files=[SOURCE], scaledActor=False) == set()
        assert query(client, files=[SOURCE, TARGET], preset='conflicts') == set()
        for args in ({'elementValueContains': ''}, {'editorIdContains': 'x' * 1025},
                     {'editorIdContains': 1}, {'persistentPositionChanged': True},
                     {'unnecessaryPersistent': False}, {'masterIsTemporary': True},
                     {'includeMasters': True}, {'preset': 'saved-name'},
                     {'preset': 'conflicts', 'conflictThis': ['ctMaster']}):
            rejected(client, files=[SOURCE], **args)
    elif scene == 'tes4':
        from vwd_fixture import SCENE
        all_refs = {'Eligible', 'MissingResource', 'AlreadyVWD', 'Interior'}
        assert query(client, files=[SCENE], isVisibleWhenDistant=True) == {'AlreadyVWD'}
        assert query(client, files=[SCENE], isVisibleWhenDistant=False) == all_refs - {'AlreadyVWD'}
        assert query(client, files=[SCENE], hasVWDMesh=True) == all_refs - {'MissingResource'}
        assert query(client, files=[SCENE], hasVWDMesh=False) == {'MissingResource'}
        assert query(client, files=[SCENE], baseEditorIdContains='Static2048') == all_refs - {'MissingResource'}
        rejected(client, files=[SCENE], hasPrecombinedMesh=False)
    elif scene == 'reachability':
        from reachability_fixture import BASE, run
        # A current analysis is required even when selecting the false side.
        rejected(client, files=[BASE], notReachable=True)
        rejected(client, files=[BASE], notReachable=False)
        run(client)
        assert query(client, files=[BASE], signatures=['FLST'], notReachable=True) == {'IsolatedC', 'IsolatedD'}
        assert query(client, files=[BASE], signatures=['FLST'], notReachable=False) == {'ReachA', 'ReachB'}
        assert query(client, files=[BASE], signatures=['FLST'], referencesInjected=True) == set()
        assert query(client, files=[BASE], signatures=['FLST'], referencesInjected=False) == {'ReachA', 'ReachB', 'IsolatedC', 'IsolatedD'}
    after = client.call('session.get_dirty_state')
    assert before['mutationRevision'] == after['mutationRevision'], (before, after)
    assert before['dirtyFiles'] == after['dirtyFiles'], (before, after)


def main():
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument('--scene', choices=('rows', 'tes4', 'reachability'), required=True)
    parser.add_argument('--exe', type=Path, required=True)
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--artifacts', type=Path, required=True)
    args = parser.parse_args()
    exercise(Client(args.exe, args.pid, args.artifacts), args.scene)


if __name__ == '__main__':
    main()
