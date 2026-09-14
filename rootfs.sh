#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
source "$(dirname "$(readlink -f "$0")")/common.sh"
usage() {
    echo "Usage: $0 --output ROOTFS.tar [--repo URL] [--ssh-key PUBLIC_KEY] [--root-password-hash FILE]"
    echo "Build openEuler 24.03-LTS-SP3 RVA20 rootfs using DNF. Requires root."
}
output= repo=$REPO_DEFAULT ssh_key= password_hash=
while (($#)); do
    case $1 in
        --output) value "$@"; output=$2; shift 2;;
        --repo) value "$@"; repo=${2%/}; shift 2;;
        --ssh-key) value "$@"; ssh_key=$(realpath "$2"); shift 2;;
        --root-password-hash) value "$@"; password_hash=$(realpath "$2"); shift 2;;
        -h|--help) usage; exit 0;;
        *) die "unknown argument: $1";;
    esac
done
[[ -n $output ]] || { usage; exit 1; }
fresh_output "$output"
output=$(realpath -m "$output")
# Reconstruct parsed arguments for the mount-namespace re-exec.
args=(--output "$output" --repo "$repo")
[[ -z $ssh_key ]] || args+=(--ssh-key "$ssh_key")
[[ -z $password_hash ]] || args+=(--root-password-hash "$password_hash")
need dnf curl tar unshare chroot mount umount
private_mounts "${args[@]}"
check_arch
work=$(mktemp -d "$(dirname "$output")/.rvck-rootfs.XXXXXX")
root=$work/root
mkdir -p "$root/etc/yum.repos.d"
trap cleanup EXIT
curl --fail --location --retry 3 "$repo/RPM-GPG-KEY-openEuler" -o "$work/RPM-GPG-KEY-openEuler"
cat > "$work/dnf.conf" <<EOF
[main]
reposdir=$work/repos
install_weak_deps=False
keepcache=True
gpgcheck=True
[rvck-rva20]
name=openEuler 24.03 LTS SP3 RVA20
baseurl=$repo
enabled=True
gpgcheck=True
gpgkey=file://$work/RPM-GPG-KEY-openEuler
EOF
mkdir -p "$work/repos"
mount_guest "$root"
dnf -y -c "$work/dnf.conf" --installroot="$root" --releasever=24.03 \
    --forcearch=riscv64 --setopt=module_platform_id=platform:oe2403 \
    --disablerepo='*' --enablerepo=rvck-rva20 install \
    basesystem filesystem bash coreutils systemd systemd-udev passwd shadow \
    util-linux e2fsprogs dosfstools kmod dracut dracut-network \
    NetworkManager openssh-server openssh-clients iproute iputils \
    dnf rpm ca-certificates linux-firmware \
    grub2-common grub2-tools grub2-tools-minimal grub2-efi-riscv64-modules
unmount_guest
mkdir -p "$root/etc/pki/rpm-gpg" "$root/etc/ssh/sshd_config.d" "$root/etc/yum.repos.d/rvck" "$root/etc/dnf"
cp "$work/RPM-GPG-KEY-openEuler" "$root/etc/pki/rpm-gpg/"
# Isolate runtime repositories too: release packages may ship non-RVA20 repos.
printf '[main]\nreposdir=/etc/yum.repos.d/rvck\ngpgcheck=True\n' > "$root/etc/dnf/dnf.conf"
cat > "$root/etc/yum.repos.d/rvck/rvck-rva20.repo" <<EOF
[rvck-rva20]
name=openEuler 24.03 LTS SP3 RVA20
baseurl=$repo
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-openEuler
EOF
echo rvck > "$root/etc/hostname"
printf '127.0.0.1 localhost\n::1 localhost\n' > "$root/etc/hosts"
echo 'LANG=C.UTF-8' > "$root/etc/locale.conf"
: > "$root/etc/machine-id"
if [[ -n $password_hash ]]; then
    [[ -s $password_hash ]] || die "empty password hash file"
    { printf 'root:'; tr -d '\r\n' < "$password_hash"; printf '\n'; } | chroot "$root" chpasswd -e
else
    printf '%s\n' 'root:openEuler12#$' | chroot "$root" chpasswd
fi
if [[ -n $ssh_key ]]; then
    [[ -s $ssh_key ]] || die "empty SSH public key"
    install -d -m 700 "$root/root/.ssh"
    install -m 600 "$ssh_key" "$root/root/.ssh/authorized_keys"
fi
printf 'PermitRootLogin prohibit-password\n' > "$root/etc/ssh/sshd_config.d/10-rvck.conf"
chroot "$root" systemctl enable NetworkManager sshd
chroot "$root" systemctl set-default multi-user.target
# NetworkManager's default wired auto-connection provides DHCP.
tar --numeric-owner --xattrs --acls -C "$root" -cpf "$work/rootfs.tar" .
ln "$work/rootfs.tar" "$output"
echo "Rootfs: $output"
echo "Staging/cache retained: $work"
