"""Skyrim tree/split LOD scene with independently decoded LST/BTT/DDS outputs."""
import argparse
import configparser
import json
from pathlib import Path
import struct
from itm_fixture import Client, subrecord
from seq_fixture import record
from copy_modes_fixture import discover

PLUGIN = 'AutomationLODScene.esp'
WORLD = 'AutomationLODTreeWorld'
EMPTY = 'AutomationLODEmptyWorld'
SPLIT = 'AutomationLODSplitWorld'
BAD = 'AutomationLODBadWorld'
FALLBACK = 'AutomationLODFallbackWorld'
PERMUTED = 'AutomationLODPermutedWorld'
DUPLICATE = 'AutomationLODDuplicateWorld'


def group(label, kind, body):
    if isinstance(label, int): label = struct.pack('<I', label)
    return struct.pack('<4sI4sIHHHH', b'GRUP', len(body) + 24, label, kind, 0, 0, 0, 0) + body


def red_dds():
    # One opaque red DXT3 block. Header and pixels are independently inspectable.
    fields = [124, 0x81007, 4, 4, 16, 0, 1] + [0] * 11
    fields += [32, 4, int.from_bytes(b'DXT3', 'little'), 0, 0, 0, 0, 0]
    fields += [0x1000, 0, 0, 0, 0]
    return b'DDS ' + struct.pack('<31I', *fields) + struct.pack('<QHHI', 0xFFFFFFFFFFFFFFFF, 0xF800, 0xF800, 0)


def fixtures():
    header = subrecord(b'HEDR', struct.pack('<fII', 1.7, 10, 0x900))
    header += subrecord(b'MAST', b'Skyrim.esm\0') + subrecord(b'DATA', b'\0' * 8)
    tree = record(b'TREE', subrecord(b'EDID', b'AutomationLODTree\0') +
                  subrecord(b'OBND', struct.pack('<6h', 0, 0, 0, 64, 64, 128)) +
                  subrecord(b'MODL', b'Landscape\\Trees\\AutomationLODTree.nif\0'), 0x01000801)
    cell = record(b'CELL', subrecord(b'EDID', b'AutomationLODCell\0') +
                  subrecord(b'DATA', b'\0\0') + subrecord(b'XCLC', struct.pack('<iii', 0, 0, 0)), 0x01000802)
    reference = record(b'REFR', subrecord(b'EDID', b'AutomationLODRef\0') +
                       subrecord(b'NAME', struct.pack('<I', 0x01000801)) +
                       subrecord(b'DATA', struct.pack('<6f', 128, 256, 32, 0, 0, 0)), 0x01000803, 0x8000)
    children = cell + group(0x01000802, 6, group(0x01000802, 9, reference))
    exterior = group(0, 4, group(0, 5, children))
    worlds = record(b'WRLD', subrecord(b'EDID', WORLD.encode() + b'\0'), 0x01000800)
    worlds += group(0x01000800, 1, exterior)
    for identity, name in ((0x01000804, EMPTY), (0x01000805, SPLIT), (0x01000806, BAD),
                           (0x01000807, FALLBACK), (0x01000808, PERMUTED), (0x01000809, DUPLICATE)):
        worlds += record(b'WRLD', subrecord(b'EDID', name.encode() + b'\0'), identity)
    result = {PLUGIN: record(b'TES4', header) + group(b'TREE', 0, tree) + group(b'WRLD', 0, worlds)}
    for name in (WORLD, EMPTY, SPLIT, BAD, FALLBACK, PERMUTED, DUPLICATE):
        result[f'lodsettings/{name}.lod'] = struct.pack('<hhiii', 0, 0, 4, 4, 16)
    billboard = f'Textures/Terrain/LODGen/{PLUGIN}/AutomationLODTree_00000801'
    result[billboard + '.dds'] = red_dds()
    result[billboard + '.txt'] = b'[LOD]\nWidth=64\nHeight=128\n'
    result[f'Meshes/Terrain/{SPLIT}/Trees/{SPLIT}.lst'] = struct.pack('<ii6fi', 1, 0, 64, 128, 0, 0, 1, 1, 0)
    result[f'Textures/Terrain/{SPLIT}/Trees/{SPLIT}TreeLod.dds'] = red_dds()
    result[f'Meshes/Terrain/{BAD}/Trees/{BAD}.lst'] = struct.pack('<i', -1)
    result[f'Textures/Terrain/{BAD}/Trees/{BAD}TreeLod.dds'] = red_dds()
    result[f'Meshes/Terrain/{SPLIT}/Trees/{SPLIT}.4.0.0.btt'] = struct.pack('<iii5fIii', 1, 0, 1, 128, 256, 32, 0, 1, 0x01000803, 0, 0)
    result[f'Meshes/Terrain/{FALLBACK}/Trees/{FALLBACK}.lst'] = struct.pack('<ii6fi', 1, 0, 64, 128, 0, 0, 1, 1, 0)
    result[f'Textures/Terrain/{FALLBACK}/Trees/{FALLBACK}TreeLod.dds'] = red_dds()
    for name, indices in ((PERMUTED, (1, 0)), (DUPLICATE, (0, 0))):
        result[f'Meshes/Terrain/{name}/Trees/{name}.lst'] = struct.pack('<i', 2) + b''.join(
            struct.pack('<i6fi', index, 64, 128, column / 2, 0, (column + 1) / 2, 1, 0)
            for column, index in enumerate(indices))
        result[f'Textures/Terrain/{name}/Trees/{name}TreeLod.dds'] = red_dds()
    return result


def read_lst(path):
    data = path.read_bytes()
    count = struct.unpack_from('<i', data)[0]
    assert count >= 0 and len(data) == 4 + count * 32, (count, len(data))
    return [struct.unpack_from('<i6fi', data, 4 + i * 32) for i in range(count)]


def read_btt(path):
    data = path.read_bytes()
    types = struct.unpack_from('<i', data)[0]
    offset, rows = 4, []
    for _ in range(types):
        index, count = struct.unpack_from('<ii', data, offset)
        offset += 8
        assert count >= 0 and offset + count * 32 <= len(data)
        rows.extend((index, struct.unpack_from('<5fIii', data, offset + i * 32)) for i in range(count))
        offset += count * 32
    assert offset == len(data)
    return rows


def dds_first_block(path):
    data = path.read_bytes()
    assert data[:4] == b'DDS ' and struct.unpack_from('<I', data, 4)[0] == 124
    height, width = struct.unpack_from('<II', data, 12)
    assert data[84:88] == b'DXT3', data[84:88]
    alpha, left, right, indices = struct.unpack_from('<QHHI', data, 128)
    def rgb(code): return ((code >> 11) * 255 // 31, ((code >> 5) & 63) * 255 // 63, (code & 31) * 255 // 31)
    colors = [rgb(left), rgb(right)]
    colors += [tuple((2 * colors[0][i] + colors[1][i]) // 3 for i in range(3)),
               tuple((colors[0][i] + 2 * colors[1][i]) // 3 for i in range(3))]
    pixels = [(*colors[(indices >> (i * 2)) & 3], ((alpha >> (i * 4)) & 15) * 17) for i in range(16)]
    return width, height, pixels


def verify(overlay):
    trees = overlay / 'OutputTrees' / WORLD
    entries = read_lst(trees / f'Meshes/Terrain/{WORLD}/Trees/{WORLD}.lst')
    assert len(entries) == 1 and entries[0][0] == 0 and entries[0][1:3] == (64, 128), entries
    blocks = list(trees.rglob('*.btt'))
    rows = [row for path in blocks for row in read_btt(path)]
    assert len(rows) == 1 and rows[0][0] == 0, rows
    ref = rows[0][1]
    assert ref[:3] == (128, 256, 32) and ref[4] == 1 and ref[5] == 0x01000803, rows
    width, height, pixels = dds_first_block(trees / f'Textures/Terrain/{WORLD}/Trees/{WORLD}TreeLod.dds')
    assert width >= 4 and height >= 4
    assert all(r > 240 and g < 16 and b < 16 and a > 240 for r, g, b, a in pixels), pixels
    split = overlay / 'OutputSplit' / SPLIT
    textures = list(split.rglob('*.dds'))
    assert len(textures) == 1 and textures[0].name == 'AutomationLODTree_00000801.dds', textures
    assert textures[0].parent.name == PLUGIN, textures
    width, height, pixels = dds_first_block(textures[0])
    assert (width, height) == (4, 4)
    assert all(r > 240 and g < 16 and b < 16 and a > 240 for r, g, b, a in pixels)
    config = configparser.ConfigParser()
    config.read(textures[0].with_suffix('.txt'))
    assert config.getfloat('LOD', 'Width') == 64 and config.getfloat('LOD', 'Height') == 128
    assert config.get('LOD', 'Model') == 'Landscape\\Trees\\AutomationLODTree.nif'
    fallback = list((overlay / 'OutputFallback' / FALLBACK).rglob('*.dds'))
    assert len(fallback) == 1 and fallback[0].name == 'Tree Type 0.dds', fallback
    assert dds_first_block(fallback[0]) == (4, 4, [(255, 0, 0, 255)] * 16)


def run(client, worlds, root, operation='generate', dry=False):
    options = dict(outputRoot=str(root.resolve()), operation=operation, objects=False, trees=operation == 'generate')
    job = client.call('jobs.start', kind='lod.generate', dryRun=dry, target={'worldspaces': worlds}, options=options)
    assert job['progress']['unit'] == 'worldspace' and job['progress']['completed'] == 0, job
    for _ in range(20000):
        job = client.call('jobs.get', jobId=job['jobId'])
        if job['terminal']: break
    assert job['terminal'], job
    client.call('jobs.discard', jobId=job['jobId'])
    return job


def exercise(client, overlay):
    worlds = discover(client, PLUGIN, 'WRLD')
    before = client.call('session.get_dirty_state')
    plan = run(client, [worlds[WORLD]], overlay / 'OutputDry', dry=True)
    assert plan['state'] == 'succeeded' and plan['result']['worldspaces'][0]['outcome'] == 'planned', plan
    assert not (overlay / 'OutputDry' / WORLD).exists()
    tree = run(client, [worlds[WORLD]], overlay / 'OutputTrees')
    assert tree['state'] == 'succeeded' and tree['result']['worldspaces'][0]['generatedFiles'] > 0, tree
    split = run(client, [worlds[SPLIT]], overlay / 'OutputSplit', 'splitAtlas')
    assert split['state'] == 'succeeded' and split['result']['worldspaces'][0]['generatedFiles'] == 2, split
    fallback = run(client, [worlds[FALLBACK]], overlay / 'OutputFallback', 'splitAtlas')
    assert fallback['state'] == 'succeeded' and fallback['result']['worldspaces'][0]['generatedFiles'] == 2, fallback
    bad = run(client, [worlds[BAD]], overlay / 'OutputMalformed', 'splitAtlas')
    assert bad['state'] == 'failed' and 'LST' in bad['failure']['message'], bad
    for name, directory in ((PERMUTED, 'OutputPermuted'), (DUPLICATE, 'OutputDuplicate')):
        malformed = run(client, [worlds[name]], overlay / directory, 'splitAtlas')
        assert malformed['state'] == 'failed' and 'LST' in malformed['failure']['message'], malformed
        assert malformed['result']['worldspaces'][0]['generatedFiles'] == 0, malformed
    empty = run(client, [worlds[EMPTY]], overlay / 'OutputEmpty')
    assert empty['state'] == 'succeeded' and empty['result']['worldspaces'][0]['outcome'] == 'no-output', empty
    options = dict(outputRoot=str((overlay / 'OutputCancel').resolve()), objects=False, trees=True)
    job = client.call('jobs.start', kind='lod.generate', dryRun=False,
                      target={'worldspaces': [worlds[WORLD], worlds[EMPTY]]}, options=options)
    for _ in range(20000):
        job = client.call('jobs.get', jobId=job['jobId'])
        if job['progress']['completed'] == 1: break
        assert not job['terminal'], job
    assert job['progress']['completed'] == 1 and not job['terminal'], job
    canceled = client.call('jobs.cancel', jobId=job['jobId'])
    assert canceled['state'] == 'canceled' and canceled['summary']['partialChanges'], canceled
    assert not (overlay / 'OutputCancel' / EMPTY).exists()
    client.call('jobs.discard', jobId=job['jobId'])
    refused = client.request(json.dumps({'command': 'jobs.start', 'args': dict(kind='lod.generate', dryRun=False,
              target={'worldspaces': [worlds[WORLD]]}, options={**options, 'outputRoot': str((overlay / 'OutputTrees').resolve())})}))
    assert not refused['ok'] and refused['error']['code'] == 'state_conflict', refused
    after = client.call('session.get_dirty_state')
    assert before['mutationRevision'] == after['mutationRevision'] and before['dirtyFiles'] == after['dirtyFiles']
    verify(overlay)


def main():
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument('phase', choices=('generate', 'exercise', 'verify'))
    parser.add_argument('--overlay', type=Path, required=True)
    parser.add_argument('--exe', type=Path)
    parser.add_argument('--pid', type=int)
    parser.add_argument('--artifacts', type=Path)
    args = parser.parse_args()
    if args.phase == 'generate':
        for name, data in fixtures().items():
            target = args.overlay / name
            target.parent.mkdir(parents=True, exist_ok=True)
            with target.open('xb') as stream: stream.write(data)
        for name in ('OutputDry', 'OutputTrees', 'OutputSplit', 'OutputFallback', 'OutputMalformed',
                     'OutputPermuted', 'OutputDuplicate', 'OutputEmpty', 'OutputCancel'):
            (args.overlay / name).mkdir()
    elif args.phase == 'verify': verify(args.overlay)
    else:
        if args.exe is None or args.pid is None or args.artifacts is None:
            parser.error('Exercise requires --exe, --pid and --artifacts')
        exercise(Client(args.exe, args.pid, args.artifacts), args.overlay)


if __name__ == '__main__': main()
