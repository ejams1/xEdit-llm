"""FO4 global reachability fixture; generate only into a dedicated MO2 overlay."""
import argparse
from pathlib import Path
import struct
from itm_fixture import Client, record, subrecord

BASE = 'AutomationReachBase.esm'
PATCH = 'AutomationReachRoot.esp'

def group(signature, body):
    return struct.pack('<4sI4sIHHHH', b'GRUP', len(body) + 24, signature, 0, 0, 0, 0, 0) + body

def plugin(masters, groups, count, esm=False):
    data = subrecord(b'HEDR', struct.pack('<fII', 1.0, count, 0x900))
    for name in masters:
        data += subrecord(b'MAST', name.encode() + b'\0') + subrecord(b'DATA', b'\0' * 8)
    return record(b'TES4', data, int(esm)) + groups

def fixtures():
    lists = b''
    for index, (name, link) in enumerate((('ReachA', 0x01000801), ('ReachB', 0x01000800),
                                          ('IsolatedC', 0x01000803), ('IsolatedD', 0x01000802)), 0x800):
        data = subrecord(b'EDID', name.encode() + b'\0') + subrecord(b'LNAM', struct.pack('<I', link))
        lists += record(b'FLST', data, form_id=0x01000000 + index)
    root = subrecord(b'EDID', b'ReachRoot\0') + subrecord(b'DATA', struct.pack('<I', 0x01000800))
    return {BASE: plugin(['Fallout4.esm'], group(b'FLST', lists), 4, True),
            PATCH: plugin(['Fallout4.esm', BASE], group(b'DFOB', record(b'DFOB', root, form_id=0x02000800)), 1)}

def run(client, roots=None, dry=False):
    target = {'files': [BASE, PATCH]}
    if roots is not None: target['roots'] = roots
    job = client.call('jobs.start', kind='analysis.reachability', target=target, dryRun=dry)
    for _ in range(1000):
        job = client.call('jobs.get', jobId=job['jobId'])
        if job['terminal']: break
    assert job['state'] == 'succeeded', job
    findings = client.call('jobs.findings', jobId=job['jobId'], limit=500)['findings']
    client.call('jobs.discard', jobId=job['jobId'])
    return job, {row['editorId']: row for row in findings}

def exercise(client):
    before = client.call('session.get_dirty_state')
    planned, rows = run(client, dry=True)
    assert not rows and not planned.get('summary', {}).get('analysisComplete', False), planned
    for _ in range(2):
        job, rows = run(client)
        assert job['summary']['analysisComplete'] and job['progress']['unit'] == 'native-stage', job
        assert rows['ReachA']['reachable'] and rows['ReachB']['reachable'], rows
        assert rows['IsolatedC']['notReachable'] and rows['IsolatedD']['notReachable'], rows
    root = {'file': BASE, 'formId': rows['IsolatedC']['formId']}
    _, explicit = run(client, [root])
    assert explicit['IsolatedC']['reachable'] and explicit['IsolatedD']['reachable'], explicit
    _, rebuilt = run(client)
    assert rebuilt['IsolatedC']['notReachable'] and rebuilt['IsolatedD']['notReachable'], rebuilt
    # Cancel after references and before the global reset/root pass completes.
    job = client.call('jobs.start', kind='analysis.reachability', target={'files': [BASE]}, dryRun=False)
    job = client.call('jobs.get', jobId=job['jobId'])
    client.call('jobs.cancel', jobId=job['jobId'])
    job = client.call('jobs.get', jobId=job['jobId'])
    assert job['state'] == 'canceled' and not job.get('summary', {}).get('analysisComplete', False), job
    client.call('jobs.discard', jobId=job['jobId'])
    run(client)
    after = client.call('session.get_dirty_state')
    assert before['mutationRevision'] == after['mutationRevision'] and before['dirtyFiles'] == after['dirtyFiles']

def main():
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument('phase', choices=('generate', 'exercise'))
    parser.add_argument('--overlay', type=Path, required=True)
    parser.add_argument('--exe', type=Path)
    parser.add_argument('--pid', type=int)
    parser.add_argument('--artifacts', type=Path)
    args = parser.parse_args()
    if args.phase == 'generate':
        args.overlay.mkdir(parents=True, exist_ok=True)
        for name, data in fixtures().items(): (args.overlay / name).write_bytes(data)
        (args.overlay / 'plugins.txt').write_text('Fallout4.esm\n' + BASE + '\n' + PATCH + '\n')
    else:
        exercise(Client(args.exe, args.pid, args.artifacts))

if __name__ == '__main__': main()
