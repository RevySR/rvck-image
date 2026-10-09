#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Exercise kernel inputs without root, mounts or a full kernel build."""
import bz2
import gzip
import lzma
import shutil
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
VERSION = '7.3.0-test'


def run(*args, **kwargs):
    return subprocess.run(args, text=True, capture_output=True, **kwargs)


def image_header():
    header = bytearray(64)
    header[:2] = b'MZ'
    struct.pack_into('<Q', header, 8, 0x200000)
    struct.pack_into('<Q', header, 16, 64)
    struct.pack_into('<I', header, 32, 2)
    header[48:56] = b'RISCV\0\0\0'
    header[56:60] = b'RSC\x05'
    return header


class Inputs(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='image-inputs-')
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.payload = self.path / 'payload'
        (self.payload / 'boot').mkdir(parents=True)
        kernel = self.payload / f'boot/vmlinuz-{VERSION}'
        kernel.write_bytes(image_header())
        modules = self.payload / f'lib/modules/{VERSION}'
        modules.mkdir(parents=True)
        (modules / 'modules.order').write_text('')
        (modules / 'modules.builtin').write_text('')
        (modules / 'fixture.ko').write_bytes(b'module extraction fixture')

    def packages(self, *args):
        result = run(str(REPO / 'rootfs.sh'), *args, '--print-packages')
        self.assertEqual(result.returncode, 0, result.stderr)
        return set(result.stdout.splitlines())

    def test_profiles_have_no_kernel(self):
        for distro, isa in [('ruyi', 'rva20'), ('ruyi', 'rva23'),
                            ('euler', 'rva20')]:
            with self.subTest(distro=distro, isa=isa):
                names = self.packages('--distro', distro, '--isa', isa)
                self.assertFalse(names & {'linux', 'kernel', 'linux-core',
                                          'kernel-core', 'linux-modules'})
                self.assertIn('linux-firmware', names)
                self.assertIn('dracut', names)
                expected = 'grub' if distro == 'ruyi' else 'grub2-tools'
                self.assertIn(expected, names)

    def test_invalid_profile(self):
        for args in [('--distro', 'bad'), ('--isa', 'bad'),
                     ('--distro', 'euler', '--isa', 'rva23')]:
            result = run(str(REPO / 'rootfs.sh'), *args,
                         '--print-packages')
            self.assertNotEqual(result.returncode, 0)

    def test_kernel_input_required_and_exclusive(self):
        dummy = str(REPO / 'README.md')
        for args in [(), ('--kernel-image', dummy),
                     ('--kernel-rpm', dummy, '--kernel-deb', dummy),
                     ('--kernel-tree', dummy, '--kernel-deb', dummy)]:
            result = run(str(REPO / 'image.sh'), '--rootfs', dummy,
                         '--output', str(self.path / 'unused.img'), *args)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('select one kernel input', result.stderr)
            self.assertFalse((self.path / 'unused.img').exists())

    def install(self, mode, *inputs, expected_error=None):
        work = self.path / 'work'
        work.mkdir(exist_ok=True)
        # Execute the same staging function used by image.sh. No chroot.
        script = '''
source "$1/common.sh"
source "$1/kernel.sh"
work=$2
root=$work/root
mkdir -p "$root" "$work/kernel"
kernel_tree= kernel_deb= kernel_image= kver=
kernel_rpms=()
cross_compile=riscv64-linux-gnu- jobs=1 grub_dir=/boot/grub
mode=$3
shift 3
case $mode in
    deb) kernel_deb=$1;;
    rpm) kernel_rpms=("$@");;
    tree) kernel_tree=$1;;
esac
resolve_kernel_rpms
install_kernel
printf '%s' "$kver" > "$work/version"
'''
        result = run('bash', '-c', script, 'test', str(REPO), str(work),
                     mode, *map(str, inputs))
        if expected_error:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(expected_error, result.stderr)
            return
        self.assertEqual(result.returncode, 0,
                         result.stdout + result.stderr)
        self.assertEqual((work / 'version').read_text(), VERSION)
        kernel = work / f'root/boot/vmlinuz-{VERSION}'
        self.assertEqual(kernel.read_bytes(), image_header())
        module = work / f'root/usr/lib/modules/{VERSION}/fixture.ko'
        self.assertEqual(module.read_bytes(), b'module extraction fixture')

    def deb(self, arch='riscv64'):
        control = self.payload / 'DEBIAN'
        control.mkdir()
        (control / 'control').write_text(
            'Package: linux-image-test\nVersion: 1\n'
            f'Architecture: {arch}\n'
            'Maintainer: Image tests <tests@example.invalid>\n'
            'Description: Kernel input extraction fixture\n')
        package = self.path / 'kernel.deb'
        result = run('dpkg-deb', '--build', '--root-owner-group',
                     str(self.payload), str(package))
        self.assertEqual(result.returncode, 0, result.stderr)
        return package

    @unittest.skipUnless(shutil.which('dpkg-deb'), 'needs dpkg-deb')
    def test_deb_kernel(self):
        self.install('deb', self.deb())

    @unittest.skipUnless(shutil.which('dpkg-deb'), 'needs dpkg-deb')
    def test_wrong_architecture(self):
        self.install('deb', self.deb('amd64'),
                     expected_error='kernel .deb is not riscv64')

    @unittest.skipUnless(shutil.which('dpkg-deb'), 'needs dpkg-deb')
    def test_kernel_without_efi_stub(self):
        kernel = self.payload / f'boot/vmlinuz-{VERSION}'
        header = image_header()
        header[:2] = b'\x00\x00'
        kernel.write_bytes(header)
        self.install('deb', self.deb(),
                     expected_error='kernel lacks an EFI stub')

    @unittest.skipUnless(shutil.which('make'), 'needs make')
    def test_source_tree(self):
        tree = self.path / 'source'
        (tree / 'arch/riscv/boot').mkdir(parents=True)
        (tree / 'arch/riscv/boot/Image').write_bytes(image_header())
        (tree / '.config').write_text('CONFIG_EFI=y\n')
        (tree / 'System.map').write_text('fixture\n')
        # A small Makefile exercises the build/install interface only.
        (tree / 'Makefile').write_text(
            '.PHONY: Image modules kernelrelease modules_install\n'
            'Image modules:\n\t@true\n'
            f'kernelrelease:\n\t@echo {VERSION}\n'
            'modules_install:\n'
            '\tmkdir -p "$(INSTALL_MOD_PATH)/lib/modules"\n'
            f'\tcp -a "{self.payload}/lib/modules/{VERSION}" '
            '"$(INSTALL_MOD_PATH)/lib/modules/"\n')
        self.install('tree', tree)

    @unittest.skipUnless(all(shutil.which(x) for x in
                            ('rpmbuild', 'rpm2cpio', 'cpio')), 'needs RPM')
    def test_split_kernel_rpms(self):
        self.install('rpm', *self.rpms())

    @unittest.skipUnless(all(shutil.which(x) for x in
                            ('rpmbuild', 'rpm2cpio', 'cpio')), 'needs RPM')
    def test_kernel_rpm_directory(self):
        packages = self.rpms()
        directory = self.path / 'kernel rpms'
        directory.mkdir()
        for package in packages:
            shutil.copy(package, directory)
        (directory / 'README').write_text('not a package')
        # Mixing a directory, an explicit file and its symlink is supported.
        alias = self.path / 'alias.rpm'
        alias.symlink_to(directory / packages[0].name)
        self.install('rpm', directory, directory / packages[0].name, alias)

    def test_rpm_input_resolution(self):
        directory = self.path / 'kernel rpms'
        directory.mkdir()
        for name in ('b.rpm', 'a.rpm', 'README'):
            (directory / name).write_text('fixture')
        nested = directory / 'nested'
        nested.mkdir()
        (nested / 'ignored.rpm').write_text('fixture')
        result = run('bash', '-c', '''
source "$1/common.sh"
source "$1/kernel.sh"
kernel_rpms=("$2" "$2/a.rpm")
resolve_kernel_rpms
printf '%s\\n' "${kernel_rpms[@]}"
''', 'test', str(REPO), str(directory))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(),
                         [str(directory / 'a.rpm'), str(directory / 'b.rpm')])

    def test_multiple_rpm_cli_arguments(self):
        dummy = str(REPO / 'README.md')
        # Reaching jobs validation proves all RPM paths/options were consumed.
        result = run(str(REPO / 'image.sh'), '--rootfs', dummy,
                     '--output', str(self.path / 'unused.img'),
                     '--kernel-rpm', dummy, dummy, '--kernel-rpm', dummy,
                     '--jobs', '0')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('jobs must be positive', result.stderr)

    @unittest.skipUnless(all(shutil.which(x) for x in
                            ('rpmbuild', 'rpm2cpio', 'cpio')), 'needs RPM')
    def test_noarch_modules_rpm(self):
        self.install('rpm', *self.rpms(modules_noarch=True))

    @unittest.skipUnless(all(shutil.which(x) for x in
                            ('rpmbuild', 'rpm2cpio', 'cpio')), 'needs RPM')
    def test_wrong_rpm_architecture(self):
        self.install('rpm', *self.rpms(arch='x86_64'),
                     expected_error='kernel RPM is not riscv64 or noarch')
        self.assertFalse((self.path / 'work/kernel/boot').exists())

    @unittest.skipUnless(all(shutil.which(x) for x in
                            ('rpmbuild', 'rpm2cpio', 'cpio')), 'needs RPM')
    def test_source_rpm_rejected(self):
        self.install('rpm', *self.rpms(source=True),
                     expected_error='source RPM cannot supply a kernel')
        self.assertFalse((self.path / 'work/kernel/kernel.spec').exists())

    def test_invalid_rpm_inputs(self):
        dummy = str(REPO / 'README.md')
        empty = self.path / 'empty'
        empty.mkdir()
        for paths, error in [
                ([str(empty)], 'no RPM files in directory'),
                ([str(self.path / 'missing.rpm')], 'kernel RPM does not exist'),
                ([dummy, str(empty)], 'no RPM files in directory'),
                ([], 'missing value for --kernel-rpm')]:
            result = run(str(REPO / 'image.sh'), '--rootfs', dummy,
                         '--output', str(self.path / 'unused.img'),
                         '--kernel-rpm', *paths)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(error, result.stderr)
            self.assertFalse((self.path / 'unused.img').exists())

    @unittest.skipUnless(all(shutil.which(x) for x in
                            ('rpmbuild', 'rpm2cpio', 'cpio', 'gzip')),
                         'needs RPM and gzip')
    def test_gzip_kernel_in_modules_directory(self):
        kernel = self.payload / f'boot/vmlinuz-{VERSION}'
        kernel.unlink()
        modules = self.payload / f'lib/modules/{VERSION}'
        (modules / 'vmlinuz').write_bytes(gzip.compress(image_header()))
        (modules / 'config').write_text('CONFIG_EFI=y\n')
        (modules / 'System.map').write_text('fixture symbols\n')
        self.install('rpm', *self.rpms(module_kernel=True))
        boot = self.path / 'work/root/boot'
        self.assertEqual((boot / f'config-{VERSION}').read_text(),
                         'CONFIG_EFI=y\n')
        self.assertEqual((boot / f'System.map-{VERSION}').read_text(),
                         'fixture symbols\n')

    def test_compressed_images(self):
        compressors = [('gzip', gzip.compress), ('bzip2', bz2.compress),
                       ('xz', lzma.compress),
                       ('lzma', lambda b: lzma.compress(
                           b, format=lzma.FORMAT_ALONE))]
        for tool, compress in compressors:
            if not shutil.which(tool):
                continue
            with self.subTest(compression=tool):
                image = self.path / 'compressed'
                output = self.path / 'Image'
                image.write_bytes(compress(image_header()))
                result = run('bash', '-c',
                             'source "$1/common.sh"; '
                             'source "$1/kernel.sh"; '
                             'prepare_kernel_image "$2" "$3"',
                             'test', str(REPO), str(image), str(output))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(output.read_bytes(), image_header())

    @unittest.skipUnless(shutil.which('dpkg-deb') and shutil.which('gzip'),
                         'needs dpkg-deb and gzip')
    def test_corrupt_gzip(self):
        kernel = self.payload / f'boot/vmlinuz-{VERSION}'
        kernel.write_bytes(gzip.compress(image_header())[:-8])
        self.install('deb', self.deb(),
                     expected_error='cannot decompress kernel')

    @unittest.skipUnless(shutil.which('dpkg-deb') and shutil.which('gzip'),
                         'needs dpkg-deb and gzip')
    def test_compressed_non_kernel(self):
        kernel = self.payload / f'boot/vmlinuz-{VERSION}'
        kernel.write_bytes(gzip.compress(b'not a kernel'))
        self.install('deb', self.deb(),
                     expected_error='decompressed kernel is not a RISC-V')

    def rpms(self, module_kernel=False, modules_noarch=False, arch='riscv64',
             source=False):
        kernel_path = f'/boot/vmlinuz-{VERSION}'
        exclude = ghost = ''
        if module_kernel:
            ghost = f'%ghost {kernel_path}'
            kernel_path = f'/lib/modules/{VERSION}/vmlinuz'
            exclude = f'%exclude {kernel_path}'
        spec = self.path / 'kernel.spec'
        spec.write_text(f'''Name: kernel-fixture
Version: 1
Release: 1
Summary: Kernel input fixture
License: GPL-2.0
AutoReqProv: no
%description
Kernel extraction fixture.
%package modules
{'BuildArch: noarch' if modules_noarch else ''}
Summary: Module input fixture
AutoReqProv: no
%description modules
Matching module extraction fixture.
%install
mkdir -p %{{buildroot}}
cp -a {self.payload}/. %{{buildroot}}/
%files
{kernel_path}
{ghost}
%files modules
/lib/modules/{VERSION}
{exclude}
''')
        result = run('rpmbuild', '-bs' if source else '-bb', '--target', arch,
                     '--define', f'_topdir {self.path}/rpm',
                     '--define', f'_tmppath {self.path}',
                     '--define', '__os_install_post %{nil}', str(spec))
        self.assertEqual(result.returncode, 0,
                         result.stdout + result.stderr)
        package_dir = 'rpm/SRPMS' if source else 'rpm/RPMS'
        packages = sorted((self.path / package_dir).rglob('*.rpm'))
        self.assertEqual(len(packages), 1 if source else 2)
        return packages


if __name__ == '__main__':
    unittest.main()
