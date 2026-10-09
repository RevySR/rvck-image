# RISC-V disk images

Build openRuyi or openEuler root filesystems and bootable raw `.img`
files. This project is based on [RevySR/rvck-image][upstream] and keeps
its GPL-2.0 license.

| Profile | Repository | ISA | Kernel |
| --- | --- | --- | --- |
| `ruyi` | openRuyi unstable | RVA20 / RVA23 | External input |
| `euler` | openEuler 24.03-LTS-SP3 | RVA20 | External input |

The default profile is `ruyi`. It selects the common, bootstrap and
`installiso` packages from
[kiwi-image][kiwi] at revision
`2a03a5de58ae2d6ea710d81d33d8828efefcc62a`. Kiwi and its dracut modules
are excluded, along with the repository kernel. The package list also
includes filesystem and image-building dependencies. This creates an
installed disk image,
not an installer ISO. Both rootfs profiles contain userspace only.
The same rootfs can be reused with different compatible RISC-V kernels,
including RVCK, A210 or other platform trees. No board name or kernel
version is fixed by the distribution profile.

## Host requirements

Run the scripts with `sudo` on Linux. Required host commands come from
DNF5, RPM, curl, GNU tar, util-linux (sfdisk 2.41+ with `--sector-size`),
dosfstools, e2fsprogs, mtools, Python 3, file and coreutils.
Custom kernel RPM inputs also need
rpm2cpio and cpio; Debian packages need dpkg-deb. Source builds require
the kernel's build dependencies and a suitable compiler.

On a non-RISC-V host, enable a `qemu-riscv64` binfmt handler with the `F`
flag. The scripts test the existing handler without registering one.
QEMU must support the selected ISA; emulated builds use `QEMU_CPU=max`
unless overridden. RVA23 images require an RVA23-capable target.

Missing tools are reported. The scripts do not install host packages.
They download target RPMs and the selected EFI loader during a build.
Host dracut is not required: depmod and dracut run inside the rootfs.

Builds use private mount and PID namespaces. They create minimal character
nodes in the staging rootfs and mount `/proc` there for RPM hooks and
Bash process substitution. Host `/dev` and `/sys` are not bind-mounted.
The `/proc` mount is removed on exit. Thus the build is not entirely
mount-free, but needs no loop devices or physical disk access.

## openRuyi

```sh
mkdir -p out
sudo ./rootfs.sh --distro ruyi --isa rva20 \
  --output out/openruyi-rva20-rootfs.tar
sudo ./image.sh --rootfs out/openruyi-rva20-rootfs.tar \
  --kernel-rpm /path/to/kernel.riscv64.rpm \
  --output out/openruyi-rva20.img
```

For RVA23, change `--isa rva20` to `--isa rva23` and choose new output
names. The repositories are `https://boat.openruyi.cn/unstable/rva20/`
and `https://boat.openruyi.cn/unstable/rva23/`. Both use `riscv64` RPMs.
`image.sh` reads the distribution and ISA recorded in the rootfs.

The default accounts are `root` and `openruyi`, with the password hash
from the Kiwi configuration. `openruyi` belongs to `wheel`. The hostname
is `openruyi`, the timezone is UTC and the locale is `C.UTF-8`.
NetworkManager and SSH are enabled. Desktop and live installer profiles
are not included.

The initial EFI loader is openEuler GRUB. A login reminder requests:

```sh
sudo dnf5 reinstall grub
sudo openruyi-install-grub
```

The helper installs openRuyi GRUB in both its vendor directory and the
removable-media EFI path, then removes the reminder. The ESP must be
mounted at `/boot/efi`; the image's fstab provides this mount.

## openEuler

The original RVA20 workflow remains available. Supply a RISC-V kernel
RPM, Debian package, or configured source tree when creating the image:

```sh
sudo ./rootfs.sh --distro euler --isa rva20 \
  --output out/openeuler-rva20-rootfs.tar
sudo ./image.sh --rootfs out/openeuler-rva20-rootfs.tar \
  --kernel-rpm /path/to/kernel.riscv64.rpm \
  --output out/openeuler-rva20.img
```

The root password remains `openEuler12#$`, as in the original project.
The hostname is `rvck`. Root SSH password login is disabled; use a key.
This profile uses openEuler packages and `grub2-*` tools. It does not
install openRuyi account settings or the GRUB replacement reminder.

## Common options

`rootfs.sh --repo URL` overrides the selected repository. Runtime DNF
uses only that repository as well. `--cache-dir DIR` reuses RPM downloads.
`--ssh-key FILE` installs a public key for the profile's default accounts.
`--password-hash FILE` overrides their passwords with a crypt-format
hash; `--root-password-hash` remains an alias. On openRuyi it applies to
both accounts. `--print-packages` lists packages without root access.

For either distribution, select exactly one kernel source when running
`image.sh`. There is no implicit fallback to a rootfs kernel:

- `--kernel-rpm FILE`, repeatable for split kernel and modules packages.
- `--kernel-deb FILE` for a RISC-V Debian kernel package.
- `--kernel-tree DIR` for a configured source/build tree; optionally add
  `--cross-compile PREFIX` and `--jobs N`.

Custom packages are extracted without executing installation hooks or
registering them in the rootfs package database. They must include
matching modules and a RISC-V kernel Image with EFI stub support.
Raw and gzip, bzip2, xz, lzma, lz4, lzop or zstd-compressed Images are
accepted; compressed inputs require the corresponding host decompressor.
Missing decompressors are reported without installing anything. Kernel
packages using `/lib/modules/VERSION/vmlinuz` are supported, including
those with generated `/boot` entries. The matching `config` and
`System.map` are copied from either location. `--kernel-image FILE` can
override the Image. The caller must ensure it matches the modules. If several versions exist, select one
with `--kernel-version VER`. For example, use a Debian kernel package:

```sh
sudo ./image.sh --rootfs out/openruyi-rva20-rootfs.tar \
  --kernel-deb /path/to/linux-image-custom_riscv64.deb \
  --output out/openruyi-custom.img
```

Or build a configured kernel source tree directly:

```sh
sudo ./image.sh --rootfs out/openruyi-rva20-rootfs.tar \
  --kernel-tree /path/to/linux --cross-compile riscv64-linux-gnu- \
  --output out/openruyi-source.img
```

The kernel must support the target hardware and userspace ISA. A generic
rootfs does not add missing board drivers. Install matching modules into
the image; dracut includes available storage drivers without requiring
virtio to be enabled in every supplied kernel.

## Disk layout and boot

The default size is 4 GiB; change it with `--size-gib N` (minimum 4).
The GPT image contains a 512 MiB FAT32 ESP and an ext4 root partition
with the RISC-V Discoverable Partitions type. Filesystems are populated
using mtools and `mkfs.ext4 -d`, then copied into a regular sparse file.
Only paths for new image files are accepted as outputs.

Images default to 512-byte logical sectors. For UFS, select `--storage ufs`
to default to 4096-byte logical sectors:

```sh
sudo ./image.sh --rootfs out/openruyi-rva20-rootfs.tar \
  --kernel-rpm /path/to/kernel.riscv64.rpm --storage ufs \
  --output out/openruyi-ufs-4k.img
```

`--storage generic|emmc|nvme` defaults to 512 bytes. `--sector-size 512|4096`
overrides any storage default, for example `--storage nvme --sector-size 4096`
for a 4Kn namespace. Match the target's **logical** block size, not its
physical block size or the kernel's memory page size. A 512-byte-sector
image cannot be used unchanged on a 4096-byte-sector target (or vice versa).
On Linux, `blockdev --getss /dev/DEVICE` reports the logical block size.

GPT headers and partition LBAs use the selected sector size, as does the
FAT32 ESP. The ESP uses one sector per cluster for 4K sectors. Ext4 uses
4096-byte filesystem blocks. Partition byte offsets remain 1 MiB for the
ESP and 513 MiB for root, with 1 MiB reserved at the end of the image.
The selected storage and sector size are recorded in
`/usr/lib/rvck-image/disk-layout`. The supplied kernel must still include
the target's UFS controller/PHY and SCSI disk support, built in or present
in the initramfs; the storage option selects the image layout.

GRUB uses filesystem UUIDs. dracut creates a generic initramfs from
the supplied kernel and modules. EDK2 supplies the hardware description.
Default kernel command lines are `loglevel=3 audit=0 rw` for openRuyi and
`console=ttyS0,115200 earlycon loglevel=7` for openEuler. Override them
with `--cmdline STRING`. openRuyi includes a systemd-repart configuration
for growing the root partition when deployed to a larger disk.

Both profiles initially use the [openEuler EFI loader][loader], pinned
by this SHA-256:

```text
bf252892f801347e8ac001613b547d18af4618ddad79909cb133d8f70758fbc5
```

Use `--grub FILE --grub-sha256 HASH` to provide a different loader with
the required modules embedded. The scripts do not sign EFI binaries.

## Flashing through Melon Pi EDK2

Melon Pi EDK2 firmware with user-disk Fastboot support can flash these
raw images directly. Enter EDK2 Fastboot with F9 and check the target:

```sh
fastboot getvar product
fastboot getvar partition-size:emmc0
fastboot flash emmc0 out/openruyi-rva20.img
```

For an enumerated NVMe namespace, use its reported target instead:

```sh
fastboot getvar partition-size:nvme0n1
fastboot flash nvme0n1 out/openruyi-rva20.img
```

`emmc0` is the eMMC user area. `emmc0boot0` and `emmc0boot1` are firmware
boot areas and must not receive this disk image. NVMe names refer to
whole namespaces, with controllers ordered by PCI address. Check the
firmware console when several controllers are present.

Flashing replaces the target's partition table and data. The host
converts large images to sparse downloads automatically; do not use
`-S 0` or manually split the file. The firmware flushes writes and
verifies each written range. Reboot after flashing to discover the new
GPT. Older firmware exposing only boot areas must be updated first;
these commands are for EDK2 Fastboot, not the BootROM downloader.

For separate installations on multiple attached disks, build a fresh
image per disk so their filesystem UUIDs differ.

For UFS, build with `--storage ufs` and use the user-data LUN target
reported by your firmware, after confirming its logical block size.
UFS Fastboot availability and target names depend on the firmware; do
not use a boot LUN for this whole-disk image.

## Provenance and build files

openEuler RPM signatures are checked with its repository key. openRuyi
currently follows Kiwi's signature policy (`gpgcheck=False`); HTTPS and
repository checksums do not replace RPM signature verification.

Repository metadata, requested and installed package lists, ISA and
loader provenance are recorded in `/usr/lib/rvck-image`. Unstable is a
moving repository; these records describe a build, not a frozen snapshot.

Existing outputs are never overwritten. Staging directories are retained
beside the outputs as `.rvck-rootfs.*` and `.rvck-image.*` for inspection.
Outputs are hard links to the corresponding files in staging. Download
caches default to `.image-cache/DISTRO/ISA` beside the rootfs output.

## Validation

Run the input regression tests without root:

```sh
python3 tests/test_inputs.py -v
python3 tests/test_disk.py -v
```

The tests build small RPM and Debian fixtures, exercise the source-tree
Makefile interface and validate architecture, EFI headers and input
selection. They use no mounts, network or real kernel compilation.
Package tests are skipped if the relevant host packaging tool is absent.
Disk tests create sparse images without root or mounts, checking both
512-byte and 4096-byte GPTs, FAT32 geometry, file population and ext4
block size. They require sfdisk with `--sector-size`, dosfstools,
e2fsprogs and mtools; unavailable-tool cases are skipped.

Input tests, disk layout tests and shell syntax checks pass. Full image builds and boot
tests remain to be run for both distributions.

[upstream]: https://github.com/RevySR/rvck-image/
[kiwi]: https://github.com/openRuyi-Project/kiwi-image/blob/2a03a5de58ae2d6ea710d81d33d8828efefcc62a/image.kiwi
[loader]: https://dl-cdn.openeuler.openatom.cn/openEuler-24.03-LTS-SP3/OS/riscv64/rva20/riscv64/EFI/BOOT/grubriscv64.EFI
