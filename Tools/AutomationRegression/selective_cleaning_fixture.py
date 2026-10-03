"""Isolated ITM/UDR jobs with independent saved flags and fresh-process readback."""
import argparse
from pathlib import Path
import json
from itm_fixture import Client
from report_fixture import fixtures as report_fixtures, signatures, BASE, DIRTY, CLEAN
from localization_fixture import reject

ITM = 'AutomationSelectiveITM.esp'
UDR = 'AutomationSelectiveUDR.esp'
ITM_KIND = 'cleaning.remove_itm'
UDR_KIND = 'cleaning.undelete_and_disable_refs'

def fixtures():
    scene = report_fixtures('fo4')
    return {BASE: scene[BASE], CLEAN: scene[CLEAN], ITM: scene[DIRTY], UDR: scene[DIRTY]}

def flags(client, file, signature):
    response = client.call('records.list', file=file, signature=signature)
    assert not response['truncated'], response
    result = {}
    for entry in response['records']:
        loc = entry['locator']
        value = client.call('elements.get_value', **{**loc, 'path': 'Record Header\\Record Flags'})
        result[int(loc['formId'], 16) & 0xFFFFFF] = int(value['values']['nativeValue']['value'])
    return result

def verify(client, overlay=None):
    for file, itm_cleaned in ((ITM, True), (UDR, False)):
        keywords = flags(client, file, 'KYWD')
        assert keywords == ({0x801: 0x80000000} if itm_cleaned else {0x800: 0, 0x801: 0x80000000}), keywords
        refs = flags(client, file, 'REFR')
        assert set(refs) == {0x830}
        assert bool(refs[0x830] & 0x20) == itm_cleaned
        if not itm_cleaned: assert refs[0x830] & 0x800
        assert flags(client, file, 'NAVM') == {0x831: 0x20}
        assert 0x820 in flags(client, file, 'CELL')
        assert client.call('files.get', name=file)['file']['masters'] == ['Fallout4.esm', BASE]
        if overlay:
            saved = {sig: {identity: value for s, identity, value in signatures((overlay / file).read_bytes(), 24) if s == sig}
                     for sig in (b'KYWD', b'REFR', b'NAVM', b'CELL')}
            assert saved[b'KYWD'] == keywords
            assert bool(saved[b'REFR'][0x830] & 0x20) == itm_cleaned
            if not itm_cleaned: assert saved[b'REFR'][0x830] & 0x800
            assert saved[b'NAVM'] == {0x831: 0x20} and 0x820 in saved[b'CELL']

def run(client, kind, files, dry=None):
    args = {'kind': kind, 'target': {'files': files}}
    if dry is not None: args['dryRun'] = dry
    job = client.call('jobs.start', **args)
    for _ in range(12):
        job = client.call('jobs.get', jobId=job['jobId'])
        if job['terminal']:
            assert job['state'] == 'succeeded', job
            return job
    raise AssertionError('Selective job exceeded bounded file advances')

def exercise(client, overlay):
    before = client.call('session.get_dirty_state')
    assert not before['dirty'] and not before['pendingShutdownCount']
    for kind, file in ((ITM_KIND, ITM), (UDR_KIND, UDR)):
        for dry in (None, True):
            job = run(client, kind, [file], dry)
            assert job['dryRun'] and job['summary']['planned'] == 1 and job['summary']['applied'] == 0
            rows = job['result']['files'][0]['records']
            if kind == ITM_KIND: assert any(row.get('reason') == 'itm-has-children' for row in rows)
            else: assert any(row.get('reason') == 'unsafe-navmesh' for row in rows)
            assert client.call('session.get_dirty_state') == before
    for files in ([], [ITM, ITM.lower()], [ITM, 'MissingAutomation.esp'], [False], [ITM] * 9, [ITM, 'Fallout4.esm']):
        reject(client, 'jobs.start', kind=ITM_KIND, dryRun=False, target={'files': files})
        assert client.call('session.get_dirty_state') == before
    reject(client, 'jobs.start', kind=UDR_KIND, target={'files': [UDR]}, options={'unknown': True})
    # Cancel between files without advancing either native unit.
    queued = client.call('jobs.start', kind=ITM_KIND, target={'files': [ITM, UDR]})
    client.call('jobs.cancel', jobId=queued['jobId'])
    canceled = client.call('jobs.get', jobId=queued['jobId'])
    assert canceled['state'] == 'canceled' and canceled['progress']['completed'] == 0
    assert client.call('session.get_dirty_state') == before
    combined = run(client, ITM_KIND, [ITM, UDR], True)
    assert combined['summary']['planned'] == 2 and combined['progress']['completed'] == 2
    assert [row['fileName'] for row in combined['result']['files']] == [ITM, UDR]
    assert client.call('session.get_dirty_state') == before
    for kind, file in ((ITM_KIND, ITM), (UDR_KIND, UDR)):
        if kind == ITM_KIND:
            started = client.call('jobs.start', kind=kind, dryRun=False, target={'files': [ITM, UDR]})
            progressed = client.call('jobs.get', jobId=started['jobId'])
            assert not progressed['terminal'] and progressed['progress']['completed'] == 1
            client.call('jobs.cancel', jobId=started['jobId'])
            job = client.call('jobs.get', jobId=started['jobId'])
            assert job['state'] == 'canceled' and job['progress']['completed'] == 1
            assert [row['fileName'] for row in job['result']['files']] == [ITM]
            assert flags(client, UDR, 'KYWD') == {0x800: 0, 0x801: 0x80000000}
            assert job['summary']['dirtyFiles'] == [ITM]
        else:
            job = run(client, kind, [file], False)
            settings = job['result']['files'][0]['nativeSettings']
            loc = client.call('records.list', file=file, signature='REFR')['records'][0]['locator']
            def native(path):
                return client.call('elements.get_value', **{**loc, 'path': path})['values']['nativeValue']['value']
            if settings['setZ']: assert float(native(r'DATA\Position\Z')) == settings['z']
            if settings['setXESP']:
                assert int(native(r'XESP\Reference')) == 0x14
                assert int(native(r'XESP\Flags')) & 1
            if settings['setScale']: assert float(native('XSCL')) == settings['scale']

        assert job['summary']['planned'] == job['summary']['applied'] == 1
        assert job['summary']['changed'] and job['summary']['requiresSave']
        assert [row['outcome'] for row in job['result']['files'][0]['records']].count('applied') == 1
        revision = client.call('session.get_dirty_state')['mutationRevision']
        again = run(client, kind, [file], False)
        assert again['summary']['planned'] == again['summary']['applied'] == 0
        assert not again['summary']['changed'] and client.call('session.get_dirty_state')['mutationRevision'] == revision
    verify(client)
    # Persistence is explicit; loaded changes must not have touched source disk.
    for file in (ITM, UDR): assert (overlay / file).read_bytes() == fixtures()[file]
    client.call('session.save', files=[ITM, UDR])
    client.call('session.flush')

def main():
    p = argparse.ArgumentParser(__doc__)
    p.add_argument('phase', choices=('generate', 'exercise', 'verify', 'no-consent'))
    p.add_argument('--overlay', type=Path, required=True)
    p.add_argument('--exe', type=Path); p.add_argument('--pid', type=int); p.add_argument('--artifacts', type=Path)
    a = p.parse_args()
    if a.phase == 'generate':
        a.overlay.mkdir(parents=True, exist_ok=True)
        data = fixtures()
        if any((a.overlay / name).exists() for name in (*data, 'plugins.txt')): p.error('Choose a fresh overlay; fixtures exist')
        for name, blob in data.items(): (a.overlay / name).write_bytes(blob)
        (a.overlay / 'plugins.txt').write_text('\n'.join(('Fallout4.esm', BASE, ITM, UDR, CLEAN)) + '\n')
    else:
        if not all((a.exe, a.pid, a.artifacts)): p.error('Live phases require exe/pid/artifacts')
        client = Client(a.exe, a.pid, a.artifacts)
        if a.phase == 'exercise': exercise(client, a.overlay)
        elif a.phase == 'no-consent':
            before = client.call('session.get_dirty_state')
            for kind, file in ((ITM_KIND, ITM), (UDR_KIND, UDR)):
                response = client.request(json.dumps({'command': 'jobs.start', 'args': {
                    'kind': ' ' + kind.upper() + ' ', 'dryRun': False, 'target': {'files': [file]}}}))
                assert not response['ok'] and response['error']['code'] == 'consent_required', response
                for dry in (None, True): assert run(client, kind, [file], dry)['dryRun']
            assert client.call('session.get_dirty_state') == before
        else: verify(client, a.overlay)

if __name__ == '__main__': main()
