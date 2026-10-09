#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Validate real 512-byte/4K disk images without root, mounts or downloads."""
import os
import shutil
import struct
import subprocess
import tempfile
import unittest
import uuid
import zlib
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
MIB = 1024 * 1024
ENV = {**os.environ, 'PATH': '/usr/sbin:/usr/bin:/sbin:/bin:' + os.environ['PATH']}


def run(*args, **kwargs):
    return subprocess.run(args, text=True, capture_output=True, env=ENV, **kwargs)


def disk_tools_available():
    if not all(shutil.which(tool, path=ENV['PATH']) for tool in
               ('sfdisk', 'mkfs.vfat', 'mkfs.ext4', 'fsck.fat',
                'mcopy', 'debugfs')):
        return False
    return '--sector-size' in run('sfdisk', '--help').stdout


class Disk(unittest.TestCase):
    def test_storage_defaults_and_overrides(self):
        for storage, override, expected in [
                ('generic', '', 512), ('emmc', '', 512), ('nvme', '', 512),
                ('ufs', '', 4096), ('ufs', '512', 512),
                ('nvme', '4096', 4096)]:
            for size in (4, 1024):
                with self.subTest(storage=storage, override=override, size=size):
                    result = run('bash', '-c', '''
source "$1/common.sh"
source "$1/disk.sh"
storage=$2 sector_size=$3 size=$4
configure_disk_layout
printf '%s %s' "$sector_size" "$root_mib"
''', 'test', str(REPO), storage, override, str(size))
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout,
                                     f'{expected} {size * 1024 - 514}')

    def test_invalid_cli_options(self):
        dummy = str(REPO / 'README.md')
        for option, value, error in [
                ('--storage', 'bad', 'storage must be'),
                ('--sector-size', '0', 'sector size must be'),
                ('--sector-size', '2048', 'sector size must be'),
                ('--sector-size', '4k', 'sector size must be')]:
            with self.subTest(option=option, value=value):
                result = run(str(REPO / 'image.sh'), '--rootfs', dummy,
                             '--kernel-rpm', dummy, '--output', '/unused.img',
                             option, value)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(error, result.stderr)

    def check_gpt(self, disk, sector_size, lba):
        disk.seek(lba * sector_size)
        header = bytearray(disk.read(sector_size))
        self.assertEqual(header[:8], b'EFI PART')
        size, crc = struct.unpack_from('<II', header, 12)
        self.assertEqual(size, 92)
        struct.pack_into('<I', header, 16, 0)
        self.assertEqual(zlib.crc32(header[:size]), crc)
        current, alternate, first, last = struct.unpack_from('<QQQQ', header, 24)
        self.assertEqual(current, lba)
        total = 4 * 1024 * MIB // sector_size
        self.assertEqual(alternate, total - 1 if lba == 1 else 1)
        self.assertLessEqual(first, MIB // sector_size)
        self.assertGreaterEqual(last, (4 * 1024 - 1) * MIB // sector_size - 1)
        entries_lba, count, entry_size, entries_crc = struct.unpack_from(
            '<QIII', header, 72)
        disk.seek(entries_lba * sector_size)
        entries = disk.read(count * entry_size)
        self.assertEqual(zlib.crc32(entries), entries_crc)
        for index, start, length, type_id in [
                (0, 1, 512, 'c12a7328-f81f-11d2-ba4b-00a0c93ec93b'),
                (1, 513, 3582, '72ec70a6-cf74-40e6-bd49-4bda08e8f224')]:
            offset = index * entry_size
            self.assertEqual(uuid.UUID(bytes_le=entries[offset:offset + 16]),
                             uuid.UUID(type_id))
            begin, end = struct.unpack_from('<QQ', entries, offset + 32)
            self.assertEqual(begin * sector_size, start * MIB)
            self.assertEqual((end - begin + 1) * sector_size, length * MIB)
        return entries

    @unittest.skipUnless(disk_tools_available(), 'needs disk/filesystem tools')
    def test_real_disk_images(self):
        for storage, sector_size in [('generic', 512), ('ufs', 4096)]:
            with self.subTest(sector_size=sector_size), \
                    tempfile.TemporaryDirectory(prefix='image-disk-') as tmp:
                work = Path(tmp)
                (work / 'root').mkdir()
                (work / 'root/fixture').write_text('root fixture\n')
                (work / 'loader.efi').write_bytes(b'EFI copy fixture')
                result = run('bash', '-c', '''
source "$1/common.sh"
source "$1/disk.sh"
work=$2 storage=$3 sector_size= size=4 label=TEST distro=test
root=$work/root
root_uuid=eb4871a9-f7a5-47ef-83fb-6b61e3709c78
configure_disk_layout
create_esp
mcopy -i "$work/esp.img" "$work/loader.efi" ::/BOOTRISCV64.EFI
create_root_partition
assemble_disk
''', 'test', str(REPO), tmp, storage)
                self.assertEqual(result.returncode, 0,
                                 result.stdout + result.stderr)
                disk_path = work / 'disk.img'
                self.assertEqual(disk_path.stat().st_size, 4 * 1024 * MIB)
                with disk_path.open('rb') as disk:
                    mbr = disk.read(512)
                    self.assertEqual(mbr[510:512], b'\x55\xaa')
                    self.assertEqual(mbr[450], 0xee)
                    self.assertEqual(struct.unpack_from('<II', mbr, 454),
                                     (1, 4 * 1024 * MIB // sector_size - 1))
                    primary = self.check_gpt(disk, sector_size, 1)
                    backup = self.check_gpt(
                        disk, sector_size, 4 * 1024 * MIB // sector_size - 1)
                    self.assertEqual(primary, backup)
                    disk.seek(MIB)
                    boot = disk.read(512)
                    self.assertEqual(struct.unpack_from('<H', boot, 11)[0],
                                     sector_size)
                    self.assertEqual(struct.unpack_from('<I', boot, 28)[0],
                                     MIB // sector_size)
                    self.assertEqual(boot[82:90], b'FAT32   ')
                    if sector_size == 4096:
                        self.assertEqual(boot[13], 1)
                    reserved = struct.unpack_from('<H', boot, 14)[0]
                    fat_size = struct.unpack_from('<I', boot, 36)[0]
                    sectors = struct.unpack_from('<I', boot, 32)[0]
                    clusters = (sectors - reserved - boot[16] * fat_size) // boot[13]
                    self.assertGreaterEqual(clusters, 65525)
                    disk.seek(513 * MIB + 1024)
                    superblock = disk.read(1024)
                    self.assertEqual(superblock[56:58], b'\x53\xef')
                    self.assertEqual(struct.unpack_from('<I', superblock, 24)[0], 2)
                result = run('sfdisk', '--sector-size', str(sector_size),
                             '--verify', str(disk_path))
                self.assertEqual(result.returncode, 0, result.stderr)
                result = run('fsck.fat', '-n', str(work / 'esp.img'))
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                # Read the ESP through its actual offset in the assembled disk.
                result = run('mcopy', '-i', f'{disk_path}@@{MIB}',
                             '::/BOOTRISCV64.EFI', str(work / 'copied.efi'))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual((work / 'copied.efi').read_bytes(),
                                 (work / 'loader.efi').read_bytes())
                result = run('debugfs', '-R', 'cat /fixture', str(work / 'root.img'))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, 'root fixture\n')


if __name__ == '__main__':
    unittest.main()
