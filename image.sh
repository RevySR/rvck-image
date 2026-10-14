#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
source "$(dirname "$(readlink -f "$0")")/common.sh"
usage() {
    cat <<EOF
Usage: $0 --rootfs ROOTFS.tar --output DISK.img [options]
  --kernel-rpm PATH...    Kernel RPM files or directories; repeatable
                         Directories include immediate *.rpm files
  --kernel-deb FILE       Alternative Debian kernel package
  --kernel-tree DIR       Configured source/build tree; build Image/modules
  --cross-compile PREFIX  Source build compiler prefix
  --jobs N               Source build jobs (default: nproc)
  --kernel-version VER   Select a version from the kernel input
  --kernel-image FILE    Override Image; must match the selected modules
  --size-gib N           Image size (default: 4, minimum: 4)
  --storage TYPE         generic, emmc, nvme or ufs (default: generic)
  --sector-size N        Logical sector bytes: 512 or 4096 (UFS: 4096;
                         other storage: 512). Must match the target disk.
  --grub FILE            Local EFI loader (default: pinned openEuler GRUB)
  --grub-sha256 HASH     Expected digest for a custom EFI loader
  --cmdline STRING       Override the distribution kernel command line
Both distributions require --kernel-rpm, --kernel-deb or --kernel-tree.
The rootfs selects userspace and ISA; the supplied kernel selects hardware.
Create a GPT raw image with a 512 MiB ESP and an ext4 RISC-V root.
EOF
}
output= rootfs= kernel_deb= kernel_image= kernel_tree= grub= kver=
kernel_rpms=()
cross_compile=${CROSS_COMPILE:-} jobs=$(nproc)
size=4 cmdline= cmdline_set=0 grub_sha=$GRUB_SHA
storage=generic sector_size=
original=("$@")
while (($#)); do
    case $1 in
        --output) value "$@"; output=$2; shift 2;;
        --rootfs) value "$@"; rootfs=$(realpath "$2"); shift 2;;
        --kernel-rpm)
            value "$@"
            [[ $2 != -* ]] || die "missing value for --kernel-rpm"
            shift
            while (($#)) && [[ $1 != -* ]]; do
                kernel_rpms+=("$1")
                shift
            done;;
        --kernel-deb) value "$@"; kernel_deb=$(realpath "$2"); shift 2;;
        --kernel-tree) value "$@"; kernel_tree=$(realpath "$2"); shift 2;;
        --cross-compile) value "$@"; cross_compile=$2; shift 2;;
        --jobs) value "$@"; jobs=$2; shift 2;;
        --kernel-version) value "$@"; kver=$2; shift 2;;
        --kernel-image)
            value "$@"; kernel_image=$(realpath "$2"); shift 2;;
        --size-gib) value "$@"; size=$2; shift 2;;
        --storage) value "$@"; storage=$2; shift 2;;
        --sector-size) value "$@"; sector_size=$2; shift 2;;
        --grub) value "$@"; grub=$(realpath "$2"); shift 2;;
        --grub-sha256) value "$@"; grub_sha=$2; shift 2;;
        --cmdline) value "$@"; cmdline=$2; cmdline_set=1; shift 2;;
        -h|--help) usage; exit 0;;
        *) die "unknown argument: $1";;
    esac
done
[[ -n $output && -f $rootfs ]] || { usage; exit 1; }
sources=0
[[ -z $kernel_deb ]] || sources=$((sources+1))
[[ -z $kernel_tree ]] || sources=$((sources+1))
[[ ${#kernel_rpms[@]} == 0 ]] || sources=$((sources+1))
((sources == 1)) || die \
    "select one kernel input: --kernel-rpm, --kernel-deb or --kernel-tree"
source "$SCRIPT_DIR/kernel.sh"
resolve_kernel_rpms
[[ $jobs =~ ^[1-9][0-9]*$ ]] || die "jobs must be positive"
[[ $size =~ ^[1-9][0-9]*$ && $size -ge 4 && $size -le 1024 ]] \
    || die "size must be 4..1024 GiB"
source "$SCRIPT_DIR/disk.sh"
configure_disk_layout
[[ $grub_sha =~ ^[[:xdigit:]]{64}$ ]] || die "invalid GRUB SHA256"
[[ $cmdline =~ ^[a-zA-Z0-9._,:=/\ +\-]*$ ]] \
    || die "unsupported character in --cmdline"
fresh_output "$output"
need unshare tar sfdisk mkfs.vfat mkfs.ext4 blkid mcopy \
    chroot mount umount mknod curl sha256sum file truncate python3
sfdisk_help=$(LC_ALL=C sfdisk --help)
[[ $sfdisk_help == *--sector-size* ]] \
    || die "sfdisk with --sector-size support is required (util-linux 2.41+)"
private_mounts "${original[@]}"
output=$(realpath -m "$output")
work=$(mktemp -d "$(dirname "$output")/.rvck-image.XXXXXX")
root=$work/root
mkdir -p "$root" "$work/kernel" "$work/esp-tree/EFI"
trap cleanup EXIT
check_arch
tar --numeric-owner --xattrs --xattrs-include='*' --acls \
    -xpf "$rootfs" -C "$root"
[[ -x $root/usr/bin/bash || -x $root/bin/bash ]] || die "rootfs lacks bash"
metadata=$root/usr/lib/rvck-image
if [[ -f $metadata/distro ]]; then
    distro=$(cat "$metadata/distro")
elif [[ -f $root/usr/lib/openruyi-image/isa ]]; then
    # Accept rootfs archives made before the shared profiles were added.
    metadata=$root/usr/lib/openruyi-image
    distro=ruyi
else
    die "rootfs lacks image profile metadata; rebuild with rootfs.sh"
fi
isa=$(cat "$metadata/isa")
load_profile "$distro" "$isa"
if [[ $distro == ruyi ]]; then
    grub_prefix=grub-
    grub_dir=/boot/grub
    default_cmdline='loglevel=3 audit=0 rw'
else
    grub_prefix=grub2-
    grub_dir=/boot/grub2
    default_cmdline='earlycon loglevel=7 audit=0'
fi
((cmdline_set)) || cmdline=$default_cmdline
install_kernel
grub_source=$grub
if [[ -z $grub ]]; then
    grub_source=$GRUB_URL
    grub=$work/grubriscv64.EFI
    curl --fail --location --retry 3 "$GRUB_URL" -o "$grub"
fi
printf '%s  %s\n' "$grub_sha" "$grub" | sha256sum -c -
file "$grub" | grep -q 'RISC-V 64-bit' || die "loader is not RISC-V EFI"
root_uuid=$(python3 -c 'import uuid; print(uuid.uuid4())')
create_esp
esp_uuid=$(blkid -p -s UUID -o value "$work/esp.img")
printf 'UUID=%s / ext4 defaults,x-systemd.growfs 0 1\n' \
    "$root_uuid" > "$root/etc/fstab"
printf 'UUID=%s /boot/efi vfat umask=0077 0 2\n' \
    "$esp_uuid" >> "$root/etc/fstab"
mount_guest "$root"
chroot "$root" depmod -a "$kver"
install -D -m 755 "$SCRIPT_DIR/files/dracut/91image-ufs/module-setup.sh" \
    "$root/usr/lib/dracut/modules.d/91image-ufs/module-setup.sh"
chroot "$root" dracut --force --no-hostonly --no-hostonly-cmdline \
    "/boot/initramfs-$kver.img" "$kver"
[[ -s $root/boot/initramfs-$kver.img ]] \
    || die "dracut produced no initramfs"
mkdir -p "$root/etc/default"
cat > "$root/etc/default/grub" <<EOF
GRUB_DEFAULT=0
GRUB_TIMEOUT=10
GRUB_DISTRIBUTOR="$label"
GRUB_TERMINAL="console"
GRUB_CMDLINE_LINUX="$cmdline"
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_DISABLE_LINUX_UUID=false
GRUB_DISABLE_OS_PROBER=true
GRUB_ENABLE_BLSCFG=false
EOF
# Initial config needs no block-device probes in the staging chroot.
cat > "$root$grub_dir/grub.cfg" <<EOF
set default=0
set timeout=10
terminal_output console
menuentry '$label ($isa, $kver)' {
    search --no-floppy --fs-uuid --set=root $root_uuid
    linux /boot/vmlinuz-$kver root=UUID=$root_uuid $cmdline
    initrd /boot/initramfs-$kver.img
}
EOF
chroot "$root" "${grub_prefix}script-check" "$grub_dir/grub.cfg"
create_grubenv
unmount_guest
for directory in BOOT "$label" openEuler; do
    mkdir -p "$work/esp-tree/EFI/$directory"
    cat > "$work/esp-tree/EFI/$directory/grub.cfg" <<EOF
search --no-floppy --fs-uuid --set=root $root_uuid
set prefix=(\$root)$grub_dir
configfile \$prefix/grub.cfg
EOF
done
install -m 644 "$grub" "$work/esp-tree/EFI/BOOT/BOOTRISCV64.EFI"
install -m 644 "$grub" "$work/esp-tree/EFI/$label/grubriscv64.efi"
mcopy -i "$work/esp.img" -s "$work/esp-tree/EFI" ::/
if [[ $distro == ruyi ]]; then
    install -D -m 644 "$SCRIPT_DIR/files/grub-notice" \
        "$root/etc/motd.d/80-openruyi-grub"
    install -D -m 644 "$SCRIPT_DIR/files/grub-profile.sh" \
        "$root/etc/profile.d/openruyi-grub.sh"
fi
printf 'source=%s\nsha256=%s\n' "$grub_source" "$grub_sha" \
    > "$metadata/initial-grub"
printf 'storage=%s\nsector_size=%s\n' "$storage" "$sector_size" \
    > "$metadata/disk-layout"
create_root_partition
assemble_disk
sync "$work/disk.img"
ln "$work/disk.img" "$output"
echo "Disk image: $output ($label, $isa, kernel $kver)"
echo "Storage: $storage, logical sector size: $sector_size bytes"
echo "Staging retained: $work"
