from pathlib import Path
import struct
import tempfile
import unittest
from lod_fixture import fixtures, PLUGIN, WORLD, SPLIT, BAD, PERMUTED, DUPLICATE, red_dds, dds_first_block, read_lst, read_btt
from test_copy_modes_fixture import records


class LodFixtureTest(unittest.TestCase):
    def test_scene_contains_tree_reference_and_settings(self):
        scene = fixtures()
        by_sig = {row[0]: row for row in records(scene[PLUGIN])}
        self.assertEqual(struct.unpack('<I', by_sig[b'REFR'][2][b'NAME'])[0], by_sig[b'TREE'][1])
        self.assertEqual(struct.unpack('<6f', by_sig[b'REFR'][2][b'DATA'])[:3], (128, 256, 32))
        self.assertEqual(struct.unpack('<hhiii', scene[f'lodsettings/{WORLD}.lod']), (0, 0, 4, 4, 16))
        self.assertEqual(scene[f'Meshes/Terrain/{BAD}/Trees/{BAD}.lst'], struct.pack('<i', -1))

    def test_atlas_and_list_are_independently_decodable(self):
        with tempfile.TemporaryDirectory() as directory:
            image, listing = Path(directory) / 'atlas.dds', Path(directory) / 'trees.lst'
            image.write_bytes(red_dds())
            self.assertEqual(dds_first_block(image), (4, 4, [(255, 0, 0, 255)] * 16))
            listing.write_bytes(fixtures()[f'Meshes/Terrain/{SPLIT}/Trees/{SPLIT}.lst'])
            self.assertEqual(read_lst(listing), [(0, 64, 128, 0, 0, 1, 1, 0)])
            block = Path(directory) / 'trees.btt'
            block.write_bytes(fixtures()[f'Meshes/Terrain/{SPLIT}/Trees/{SPLIT}.4.0.0.btt'])
            self.assertEqual(read_btt(block)[0][1][5], 0x01000803)
            for name, expected in ((PERMUTED, [1, 0]), (DUPLICATE, [0, 0])):
                listing.write_bytes(fixtures()[f'Meshes/Terrain/{name}/Trees/{name}.lst'])
                self.assertEqual([row[0] for row in read_lst(listing)], expected)


if __name__ == '__main__': unittest.main()
