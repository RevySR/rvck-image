#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
source "$(dirname "$(readlink -f "$0")")/common.sh"
usage() {
    cat <<EOF
Usage: $0 --rootfs ROOTFS.tar --kernel-rpm PACKAGE --output DISK.img [options]
       $0 --rootfs ROOTFS.tar --kernel-tree DIR --output DISK.img [options]
  --kernel-rpm FILE       Kernel RPM; repeat for split kernel/modules RPMs
  --kernel-tree DIR       Configured kernel source/build tree; build and install directly
  --cross-compile PREFIX  Compiler prefix for source builds (native default: empty)
  --jobs N               Parallel source build jobs (default: nproc)
  --kernel-deb FILE       Alternative Debian kernel package input
  --kernel-image FILE     Override package Image with matching EFI-stub RISC-V Image
  --size-gib N            Disk size, default 8, minimum 4
  --repo URL              RVA20 repository containing EFI/BOOT/grubriscv64.EFI
  --grub FILE             Local monolithic RISC-V GRUB, instead of downloading
  --grub-sha256 HASH      Override expected GRUB digest (required for custom GRUB)
  --cmdline STRING        Default: console=ttyS0,115200 earlycon loglevel=7
Creates a new GPT raw image: 512 MiB FAT32 ESP + ext4 root. Requires root.
EOF
}
output= rootfs= kernel_deb= kernel_image= grub= kernel_tree=
kernel_rpms=()
cross_compile=${CROSS_COMPILE:-} jobs=$(nproc)
repo=$REPO_DEFAULT size=8 cmdline='console=ttyS0,115200 earlycon loglevel=7'
grub_sha=bf252892f801347e8ac001613b547d18af4618ddad79909cb133d8f70758fbc5
original=("$@")
while (($#)); do
    case $1 in
        --output) value "$@"; output=$2; shift 2;;
        --rootfs) value "$@"; rootfs=$(realpath "$2"); shift 2;;
        --kernel-rpm) value "$@"; kernel_rpms+=("$(realpath "$2")"); shift 2;;
        --kernel-tree) value "$@"; kernel_tree=$(realpath "$2"); shift 2;;
        --cross-compile) value "$@"; cross_compile=$2; shift 2;;
        --jobs) value "$@"; jobs=$2; shift 2;;
        --kernel-deb) value "$@"; kernel_deb=$(realpath "$2"); shift 2;;
        --kernel-image) value "$@"; kernel_image=$(realpath "$2"); shift 2;;
        --size-gib) value "$@"; size=$2; shift 2;;
        --repo) value "$@"; repo=${2%/}; shift 2;;
        --grub) value "$@"; grub=$(realpath "$2"); shift 2;;
        --grub-sha256) value "$@"; grub_sha=$2; shift 2;;
        --cmdline) value "$@"; cmdline=$2; shift 2;;
        -h|--help) usage; exit 0;;
        *) die "unknown argument: $1";;
    esac
done
[[ -n $output && -f $rootfs ]] || { usage; exit 1; }
sources=0
[[ -z $kernel_deb ]] || sources=$((sources+1))
[[ -z $kernel_tree ]] || sources=$((sources+1))
[[ ${#kernel_rpms[@]} == 0 ]] || sources=$((sources+1))
[[ $sources == 1 ]] || die "select one input: --kernel-rpm (repeatable), --kernel-tree, or --kernel-deb"
[[ $jobs =~ ^[1-9][0-9]*$ ]] || die "jobs must be a positive integer"
[[ $size =~ ^[0-9]+$ && $size -ge 4 ]] || die "size must be an integer >= 4 GiB"
[[ $grub_sha =~ ^[[:xdigit:]]{64}$ ]] || die "invalid GRUB SHA256"
# This value is written into a shell assignment in /etc/default/grub.
[[ $cmdline =~ ^[a-zA-Z0-9._,:=/\ +\-]*$ ]] || die "unsupported character in --cmdline"
fresh_output "$output"
need unshare tar sgdisk losetup mkfs.vfat mkfs.ext4 blkid \
    chroot mount umount curl sha256sum file truncate
private_mounts "${original[@]}"
check_arch
output=$(realpath -m "$output")
work=$(mktemp -d "$(dirname "$output")/.rvck-image.XXXXXX")
root=$work/root
mkdir -p "$root" "$work/kernel"
trap cleanup EXIT
if [[ -n $kernel_tree ]]; then
    need make
    [[ -f $kernel_tree/.config ]] || die "configure the kernel tree first (rvck_defconfig)"
    if [[ $(uname -m) != riscv64 && -z $cross_compile ]]; then cross_compile=riscv64-linux-gnu-; fi
    make -C "$kernel_tree" ARCH=riscv CROSS_COMPILE="$cross_compile" -j"$jobs" Image modules
    kver=$(make -s --no-print-directory -C "$kernel_tree" ARCH=riscv CROSS_COMPILE="$cross_compile" kernelrelease)
    make -C "$kernel_tree" ARCH=riscv CROSS_COMPILE="$cross_compile" \
        INSTALL_MOD_PATH="$work/kernel" DEPMOD=true modules_install
    mkdir -p "$work/kernel/boot"
    cp "$kernel_tree/.config" "$work/kernel/boot/config-$kver"
    cp "$kernel_tree/System.map" "$work/kernel/boot/System.map-$kver"
    cp "$kernel_tree/arch/riscv/boot/Image" "$work/kernel/boot/vmlinuz-$kver"
elif [[ -n $kernel_deb ]]; then
    need dpkg-deb
    [[ $(dpkg-deb -f "$kernel_deb" Architecture) == riscv64 ]] || die "kernel .deb is not riscv64"
    dpkg-deb -x "$kernel_deb" "$work/kernel"
else
    need rpm rpm2cpio cpio
    for package in "${kernel_rpms[@]}"; do
        [[ $(rpm -qp --qf '%{ARCH}' "$package") == riscv64 ]] || die "kernel RPM is not riscv64: $package"
        (cd "$work/kernel"; rpm2cpio "$package" | cpio -idm --quiet --no-absolute-filenames)
    done
fi
module_base=$work/kernel/lib/modules
[[ -d $module_base ]] || module_base=$work/kernel/usr/lib/modules
[[ -d $module_base ]] || die "no kernel modules directory; include the matching modules RPM"
mapfile -t versions < <(find "$module_base" -mindepth 1 -maxdepth 1 -type d -printf '%f\n')
[[ ${#versions[@]} == 1 ]] || die "expected exactly one kernel version across kernel inputs"
kver=${versions[0]}
[[ $kver =~ ^[a-zA-Z0-9._+-]+$ ]] || die "unsupported kernel version"
if [[ -z $kernel_image ]]; then
    for candidate in "$work/kernel/boot/vmlinuz-$kver" "$work/kernel/boot/vmlinux-$kver" \
        "$work/kernel/boot/Image-$kver" "$module_base/$kver/vmlinuz"; do
        if [[ -f $candidate ]] && file "$candidate" | grep -q 'RISC-V boot executable Image'; then
            kernel_image=$candidate; break
        fi
    done
fi
[[ -f $kernel_image ]] || die "no raw RISC-V Image in package; pass --kernel-image /path/to/Image"
file "$kernel_image" | grep -q 'RISC-V boot executable Image' || die "kernel must be an uncompressed RISC-V Image, not ELF vmlinux"
[[ $(od -An -tx1 -N2 "$kernel_image" | tr -d ' \n') == 4d5a ]] || die "kernel lacks EFI stub (MZ header)"
kernel_config=$work/kernel/boot/config-$kver
[[ -f $kernel_config ]] || kernel_config=$module_base/$kver/config
[[ -f $kernel_config ]] || die "kernel configuration missing from input"
grep -qx 'CONFIG_EFI_STUB=y' "$kernel_config" || die "kernel requires CONFIG_EFI_STUB=y"
if [[ -z $grub ]]; then
    grub=$work/grubriscv64.EFI
    curl --fail --location --retry 3 "$repo/EFI/BOOT/grubriscv64.EFI" -o "$grub"
fi
printf '%s  %s\n' "$grub_sha" "$grub" | sha256sum -c -
file "$grub" | grep -q 'RISC-V 64-bit' || die "GRUB is not RISC-V EFI"
truncate -s "${size}G" "$work/disk.img"
sgdisk --clear --new=1:2048:+512M --typecode=1:ef00 --change-name=1:ESP \
    --new=2:0:0 --typecode=2:8300 --change-name=2:rootfs "$work/disk.img"
loop=$(losetup --find --show --partscan "$work/disk.img")
for ((i=0; i<50; i++)); do [[ -b ${loop}p2 ]] && break; sleep 0.1; done
[[ -b ${loop}p2 ]] || die "loop partitions not available"
mkfs.vfat -F 32 -n RVCK_ESP "${loop}p1"
# Disable newer ext4 features that older GRUB builds may not understand.
mkfs.ext4 -F -L rvck-root -O '^metadata_csum_seed,^orphan_file' "${loop}p2"
mount "${loop}p2" "$root"; mounts+=("$root")
tar --numeric-owner --xattrs --acls -xpf "$rootfs" -C "$root"
[[ -x $root/usr/bin/bash || -x $root/bin/bash ]] || die "rootfs has no bash"
mkdir -p "$root/boot/efi" "$root/lib/modules"
cp -a "$module_base/$kver" "$root/lib/modules/"
if [[ -f $work/kernel/boot/System.map-$kver ]]; then
    install -m 644 "$work/kernel/boot/System.map-$kver" "$root/boot/System.map-$kver"
fi
install -m 644 "$kernel_config" "$root/boot/config-$kver"
# Use the conventional name detected by the distribution's 10_linux script.
install -m 644 "$kernel_image" "$root/boot/vmlinuz-$kver"
mount "${loop}p1" "$root/boot/efi"; mounts+=("$root/boot/efi")
root_uuid=$(blkid -s UUID -o value "${loop}p2")
esp_uuid=$(blkid -s UUID -o value "${loop}p1")
printf 'UUID=%s / ext4 defaults 0 1\nUUID=%s /boot/efi vfat umask=0077 0 2\n' \
    "$root_uuid" "$esp_uuid" > "$root/etc/fstab"
mount_guest "$root"
chroot "$root" depmod -a "$kver"
chroot "$root" dracut --force --no-hostonly --no-hostonly-cmdline \
    --add-drivers 'virtio_blk virtio_pci virtio_mmio' \
    "/boot/initramfs-$kver.img" "$kver"
[[ -s $root/boot/initramfs-$kver.img ]] || die "dracut produced no initramfs"
mkdir -p "$root/boot/efi/EFI/BOOT" "$root/boot/efi/EFI/openEuler" "$root/boot/grub2" "$root/boot/grub"
install -m 644 "$grub" "$root/boot/efi/EFI/BOOT/BOOTRISCV64.EFI"
install -m 644 "$grub" "$root/boot/efi/EFI/openEuler/grubriscv64.efi"
mkdir -p "$root/etc/default"
cat > "$root/etc/default/grub" <<EOF
GRUB_DEFAULT=0
GRUB_TIMEOUT=3
GRUB_DISTRIBUTOR="openEuler"
GRUB_TERMINAL="console"
GRUB_CMDLINE_LINUX="$cmdline"
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_DISABLE_LINUX_UUID=false
GRUB_DISABLE_OS_PROBER=true
GRUB_ENABLE_BLSCFG=false
EOF
# Keep /proc, /sys and /dev mounted for grub2-probe's filesystem discovery.
chroot "$root" /bin/sh -c 'command -v grub2-mkconfig >/dev/null && command -v grub2-script-check >/dev/null' \
    || die "rootfs lacks GRUB tools; rebuild it with rootfs.sh"
chroot "$root" grub2-mkconfig -o /boot/grub2/grub.cfg
chroot "$root" grub2-script-check /boot/grub2/grub.cfg
grep -Fq "vmlinuz-$kver" "$root/boot/grub2/grub.cfg" || die "grub2-mkconfig did not detect the kernel"
grep -Fq "initramfs-$kver.img" "$root/boot/grub2/grub.cfg" || die "grub2-mkconfig did not detect the initramfs"
unmount_guest
# Every entry point uses the distribution-generated configuration verbatim.
cp "$root/boot/grub2/grub.cfg" "$root/boot/grub/grub.cfg"
for dir in BOOT openEuler; do
    cp "$root/boot/grub2/grub.cfg" "$root/boot/efi/EFI/$dir/grub.cfg"
done
sync
umount "$root/boot/efi"; unset 'mounts[1]'
umount "$root"; unset 'mounts[0]'
losetup -d "$loop"; loop=
ln "$work/disk.img" "$output"
echo "Disk image: $output (kernel $kver)"
echo "Staging retained: $work"
