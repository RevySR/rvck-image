#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Check host DNF selection and installroot configuration without downloads."""
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]


class Dnf(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='image-dnf-')
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.bin = self.path / 'bin'
        self.bin.mkdir()

    def fake(self, name, version):
        path = self.bin / name
        path.write_text(f"#!/bin/bash\nprintf '%s\\n' '{version}'\n")
        path.chmod(0o755)
        return path

    def select(self, command='auto'):
        return subprocess.run(['/bin/bash', '-c', '''
source "$1/common.sh"
source "$1/dnf.sh"
PATH=$2
dnf_command=$3
select_dnf
printf '%s:%s' "$dnf_command" "$dnf_major"
''', 'test', str(REPO), str(self.bin), command],
                              text=True, capture_output=True)

    def test_selection(self):
        self.fake('dnf', '4.23.0')
        result = self.select()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'dnf:4')
        self.fake('dnf5', 'dnf5 version 5.2.17.0')
        self.assertEqual(self.select().stdout, 'dnf5:5')
        self.assertEqual(self.select('dnf').stdout, 'dnf:4')
        self.fake('dnf', 'dnf5 version 5.2.17.0')
        self.assertEqual(self.select('dnf').stdout, 'dnf:5')
        (self.bin / 'dnf').unlink()
        (self.bin / 'dnf5').unlink()
        self.fake('dnf4', '4.23.0')
        self.assertEqual(self.select().stdout, 'dnf4:4')
        explicit = self.fake('custom dnf', '4.23.0')
        self.assertEqual(self.select(str(explicit)).stdout, f'{explicit}:4')

    def test_missing_or_unsupported(self):
        result = self.select()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('dnf5 or dnf', result.stderr)
        self.fake('dnf', '3.4.0')
        result = self.select()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('expected DNF4 or DNF5', result.stderr)

    def arguments(self, major, distro):
        work = self.path / 'staging space'
        (work / 'root').mkdir(parents=True, exist_ok=True)
        (work / 'repos').mkdir(exist_ok=True)
        cache = self.path / 'shared cache'
        cache.mkdir(exist_ok=True)
        result = subprocess.run(['/bin/bash', '-c', '''
source "$1/common.sh"
source "$1/dnf.sh"
work=$2 root=$2/root cache_dir=$3 dnf_major=$4 distro=$5 isa=rva20
load_profile "$distro" "$isa"
configure_dnf_args
printf '%s\\n' "$dnf_cache_config" "$dnf_log_config" > "$work/paths.conf"
printf '%s\0' "${dnf_args[@]}"
'''.replace('\0', '\\0'), 'test', str(REPO), str(work), str(cache),
                                 str(major), distro], capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        return result.stdout.decode().rstrip('\0').split('\0'), work, cache

    def test_version_specific_arguments(self):
        for major in (4, 5):
            for distro in ('ruyi', 'euler'):
                with self.subTest(major=major, distro=distro):
                    args, work, cache = self.arguments(major, distro)
                    self.assertIn('--forcearch=riscv64', args)
                    self.assertIn(f'--setopt=reposdir={work}/repos', args)
                    self.assertEqual('--setopt=module_platform_id=platform:oe2403'
                                     in args, distro == 'euler')
                    if major == 5:
                        self.assertIn('--use-host-config', args)
                        self.assertIn(f'--setopt=system_cachedir={cache}', args)
                        self.assertIn(f'--enable-repo=image-{distro}-rva20', args)
                        self.assertIn('--disable-repo=*', args)
                    else:
                        self.assertNotIn('--use-host-config', args)
                        self.assertFalse(any('system_cachedir=' in x for x in args))
                        self.assertIn(f'--enablerepo=image-{distro}-rva20', args)
                        self.assertIn('--disablerepo=*', args)
                        for option, expected in [('cachedir', cache),
                                                 ('logdir', work / 'log')]:
                            value = next(x.split('=', 1)[1] for x in
                                         (work / 'paths.conf').read_text().splitlines()
                                         if x.startswith(f'{option}='))
                            self.assertEqual((work / 'root' / value.lstrip('/')).resolve(),
                                             expected)

    def test_real_dnf4_configuration(self):
        probe = subprocess.run(['/usr/bin/python3', '-c', 'import dnf.cli.cli'],
                               capture_output=True)
        if probe.returncode:
            self.skipTest('needs system Python DNF4 bindings')
        args, work, cache = self.arguments(4, 'ruyi')
        (work / 'dnf.conf').write_text('[main]\n' +
                                      (work / 'paths.conf').read_text() + '''gpgcheck=False
[image-ruyi-rva20]
name=fixture
baseurl=file:///unused-repository
enabled=True
[unwanted]
name=unwanted
baseurl=file:///unused-repository
enabled=True
''')
        # Relocate DNF's initial per-user temporary directory for the sandbox.
        # The real CLI parser then resolves all production installroot options.
        script = '''
import json, sys
import dnf, dnf.const, dnf.cli.cli
dnf.const.TMPDIR = sys.argv[1]
with dnf.cli.cli.BaseCli() as base:
    cli = dnf.cli.cli.Cli(base)
    cli.configure(sys.argv[2:] + ['repolist'])
    print(json.dumps(dict(cachedir=base.conf.cachedir, logdir=base.conf.logdir,
                         arch=base.conf.arch, installroot=base.conf.installroot,
                         repos=sorted(r.id for r in base.repos.iter_enabled()))))
'''
        result = subprocess.run(['/usr/bin/python3', '-c', script, str(self.path),
                                 *args], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        config = json.loads(result.stdout)
        self.assertEqual(Path(config['cachedir']).resolve(), cache)
        self.assertEqual(Path(config['logdir']).resolve(), work / 'log')
        self.assertEqual(config['installroot'], str(work / 'root'))
        self.assertEqual(config['arch'], 'riscv64')
        self.assertEqual(config['repos'], ['image-ruyi-rva20'])

    @unittest.skipUnless(all(shutil.which(x) for x in ('rpm', 'rpmbuild', 'unshare')),
                         'needs RPM and user namespaces')
    def test_native_database_transactions(self):
        probe = subprocess.run(['unshare', '--user', '--map-root-user', '--mount',
                                'true'], capture_output=True)
        if probe.returncode:
            self.skipTest('needs unprivileged mount namespaces')
        spec = self.path / 'fixture.spec'
        spec.write_text('''Name: image-db-fixture
Version: 1
Release: 1
Summary: RPM database regression fixture
License: MIT
BuildArch: noarch
%description
No scriptlets or dependencies.
%install
mkdir -p %{buildroot}/usr/share/image-db-fixture
echo fixture > %{buildroot}/usr/share/image-db-fixture/data
%files
/usr/share/image-db-fixture
''')
        result = subprocess.run(['rpmbuild', '--define', f'_topdir {self.path}/build',
                                 '--define', f'_tmppath {self.path}',
                                 '-bb', str(spec)], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        package = next((self.path / 'build/RPMS/noarch').glob('*.rpm'))
        # Reproduce Debian defaults in a private user macro file, including
        # a path with spaces. The production override must win over this file.
        config = self.path / 'config space'
        (config / 'rpm').mkdir(parents=True)
        macros = config / 'rpm/macros'
        original = '%_dbpath /root/.rpmdb\n%_db_backend sqlite\n'
        macros.write_text(original)
        env = dict(os.environ, XDG_CONFIG_HOME=str(config))
        script = '''
source "$1/common.sh"
source "$1/dnf.sh"
work=$2 root=$2/root cache_dir=$2/cache distro=ruyi isa=rva20
mkdir -p "$root" "$cache_dir" "$work/repos"
trap cleanup EXIT
# DNF --version opens host logs as root; keep test writes in the fixture.
mkdir -p "$work/host-log" "$work/host-tmp"
mount --bind "$work/host-log" /var/log
mounts+=(/var/log)
mount --bind "$work/host-tmp" /var/tmp
mounts+=(/var/tmp)
configure_rpm_database
if [[ $4 == rpm ]]; then
    rpm --root "$root" --nodeps --noscripts -i "$3"
else
    dnf_command=$4
    select_dnf
    load_profile "$distro" "$isa"
    configure_dnf_args
    printf '[main]\\n%s\\n%s\\ngpgcheck=False\\n' \\
        "$dnf_cache_config" "$dnf_log_config" > "$work/dnf.conf"
    printf '[image-ruyi-rva20]\\nname=fixture\\nbaseurl=file:///unused\\n' \\
        >> "$work/dnf.conf"
    if [[ $dnf_major == 5 ]]; then disable='--disable-repo=*';
    else disable='--disablerepo=*'; fi
    "$dnf_command" "${dnf_args[@]}" "$disable" install "$3"
    # A second process must read the same database successfully.
    "$dnf_command" "${dnf_args[@]}" "$disable" list --installed image-db-fixture
fi
rpm --root "$root" -q image-db-fixture
test -f "$root/var/lib/rpm/Packages.db"
test ! -e "$root/root/.rpmdb"
test ! -e "$root/var/lib/rpm/rpmdb.sqlite"
test ! -e "$root/etc/rpm/macros.image-db"
'''
        commands = ['rpm'] + [x for x in ('dnf', 'dnf4', 'dnf5') if shutil.which(x)]
        for command in commands:
            with self.subTest(command=command):
                work = self.path / f'{command} staging'
                result = subprocess.run(
                    ['unshare', '--user', '--map-root-user', '--mount',
                     '--propagation', 'private', '/bin/bash', '-c', script,
                     'test', str(REPO), str(work), str(package), command],
                    env=env, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('image-db-fixture', result.stdout)
                self.assertEqual(macros.read_text(), original)


if __name__ == '__main__':
    unittest.main()
