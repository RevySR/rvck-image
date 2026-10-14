#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
source "$(dirname "$(readlink -f "$0")")/common.sh"
usage() {
    cat <<EOF_USAGE
Usage: $0 --output ROOTFS.tar [options]
  --distro ruyi|euler      Distribution (default: ruyi)
  --isa rva20|rva23        Repository profile (default: rva20)
  --repo URL              Override the selected repository
  --cache-dir DIR         Reuse downloaded RPMs (default: beside output)
  --dnf COMMAND           Host DNF executable (default: auto, prefer dnf5)
  --ssh-key FILE          Public key for the default accounts
  --password-hash FILE    Override their default password hash
  --print-packages        Print the selected package list and exit
Build a reusable rootfs; supply the kernel separately to image.sh.
openRuyi uses stable; openEuler uses 24.03-LTS-SP3 for RVA20 and SP4 for RVA23.
Run with sudo. Host tools are checked, never installed automatically.
EOF_USAGE
}
output= distro=ruyi isa=rva20 repo= cache_dir= ssh_key= password_hash=
print_only=0
dnf_command=auto
original=("$@")
while (($#)); do
    case $1 in
        --output) value "$@"; output=$2; shift 2;;
        --distro) value "$@"; distro=$2; shift 2;;
        --isa) value "$@"; isa=$2; shift 2;;
        --repo) value "$@"; repo=${2%/}; shift 2;;
        --cache-dir) value "$@"; cache_dir=$(realpath -m "$2"); shift 2;;
        --dnf) value "$@"; dnf_command=$2; shift 2;;
        --ssh-key) value "$@"; ssh_key=$(realpath "$2"); shift 2;;
        --password-hash|--root-password-hash)
            value "$@"; password_hash=$(realpath "$2"); shift 2;;
        --print-packages) print_only=1; shift;;
        -h|--help) usage; exit 0;;
        *) die "unknown argument: $1";;
    esac
done
load_profile "$distro" "$isa"
repo=${repo:-$default_repo}
[[ $repo =~ ^https?://[^[:space:]]+$ ]] || die "invalid repository URL"
mapfile -t packages < <(sed '/^#/d; /^$/d' \
    "$SCRIPT_DIR/packages/$package_list")
if ((print_only)); then printf '%s\n' "${packages[@]}"; exit 0; fi
[[ -n $output ]] || { usage; exit 1; }
[[ -z $ssh_key || -s $ssh_key ]] || die "empty SSH public key"
if [[ -n $password_hash ]]; then
    [[ -s $password_hash ]] || die "empty password hash file"
    hash=$(cat "$password_hash")
    [[ -n $hash && $hash != *:* && $hash != *$'\n'* \
        && $hash != *$'\r'* ]] \
        || die "invalid password hash"
fi
fresh_output "$output"
need rpm curl tar unshare chroot mount umount mknod python3
source "$SCRIPT_DIR/dnf.sh"
select_dnf
private_mounts "${original[@]}"
output=$(realpath -m "$output")
cache_dir=${cache_dir:-$(dirname "$output")/.image-cache/$distro/$isa}
work=$(mktemp -d "$(dirname "$output")/.rvck-rootfs.XXXXXX")
root=$work/root
metadata=$root/usr/lib/rvck-image
mkdir -p "$root/etc/yum.repos.d" "$work/repos" "$cache_dir"
trap cleanup EXIT
check_arch
configure_rpm_database
curl --fail --location --retry 3 "$repo/repodata/repomd.xml" \
    -o "$work/repomd.xml"
build_key= runtime_key=
if [[ -n $repo_key ]]; then
    curl --fail --location --retry 3 "$repo/$repo_key" \
        -o "$work/$repo_key"
    build_key="gpgkey=file://$work/$repo_key"
    runtime_key="gpgkey=file:///etc/pki/rpm-gpg/$repo_key"
fi
configure_dnf_args
cat > "$work/dnf.conf" <<EOF_DNF
[main]
$dnf_cache_config
$dnf_log_config
reposdir=$work/repos
install_weak_deps=$weak_deps
keepcache=True
gpgcheck=$gpgcheck
exclude=kiwi* python*-kiwi* dracut-kiwi-* $kernel_excludes
[image-$distro-$isa]
name=$label $isa
baseurl=$repo
enabled=True
gpgcheck=$gpgcheck
$build_key
EOF_DNF
echo "Host package manager: $dnf_command (DNF$dnf_major)"
# Install the directory layout before preparing the chroot.
"$dnf_command" "${dnf_args[@]}" install filesystem
mount_guest "$root"
# Install the shell before packages with pre-transaction scriptlets.
"$dnf_command" "${dnf_args[@]}" install "${bootstrap[@]}"
# Verify native target RPM sees the host transactions before continuing.
[[ $(chroot "$root" rpm --eval '%{_dbpath}:%{_db_backend}') == /var/lib/rpm:ndb ]] \
    || die "target RPM database configuration differs from the build"
chroot "$root" rpm -q filesystem bash rpm
mkdir -p "$root/etc/dracut.conf.d"
printf 'hostonly="no"\nhostonly_cmdline="no"\n' \
    > "$root/etc/dracut.conf.d/90-image.conf"
"$dnf_command" "${dnf_args[@]}" install "${packages[@]}"
chroot "$root" /bin/bash -c 'test "$(uname -m)" = riscv64'
mkdir -p "$root/etc/yum.repos.d/image" "$metadata" "$root/etc/dnf"
cat > "$root/etc/dnf/dnf.conf" <<EOF_DNF
[main]
reposdir=/etc/yum.repos.d/image
install_weak_deps=$weak_deps
gpgcheck=$gpgcheck
EOF_DNF
cat > "$root/etc/yum.repos.d/image/image.repo" <<EOF_REPO
[image-$distro-$isa]
name=$label $isa
baseurl=$repo
enabled=1
gpgcheck=$gpgcheck
$runtime_key
EOF_REPO
if [[ -n $repo_key ]]; then
    install -D -m 644 "$work/$repo_key" \
        "$root/etc/pki/rpm-gpg/$repo_key"
fi
printf '%s\n' "$distro" > "$metadata/distro"
printf '%s\n' "$isa" > "$metadata/isa"
printf '%s\n' "$repo" > "$metadata/repository"
cp "$work/repomd.xml" "$metadata/repomd.xml"
printf '%s\n' "${packages[@]}" > "$metadata/requested-packages"
chroot "$root" rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' \
    | sort > "$metadata/packages"
if grep -E '^(kiwi|python[^-]*-kiwi|dracut-kiwi)' \
    "$metadata/packages"; then
    die "unexpected Kiwi component installed"
fi
echo "$hostname" > "$root/etc/hostname"
printf '127.0.0.1 localhost\n::1 localhost\n' > "$root/etc/hosts"
echo 'LANG=C.UTF-8' > "$root/etc/locale.conf"
ln -snf /usr/share/zoneinfo/UTC "$root/etc/localtime"
configure_rootfs
chroot "$root" systemctl enable NetworkManager.service sshd.service
chroot "$root" systemctl set-default multi-user.target
chroot "$root" update-ca-trust
: > "$root/etc/machine-id"
mkdir -p "$root/var/lib/dbus"
rm -f "$root/var/lib/dbus/machine-id" "$root/etc/ssh/ssh_host_"*
ln -s /etc/machine-id "$root/var/lib/dbus/machine-id"
unmount_guest
tar --numeric-owner --xattrs --xattrs-include='*' --acls \
    -C "$root" -cpf "$work/rootfs.tar" .
ln "$work/rootfs.tar" "$output"
echo "Rootfs: $output ($label, $isa)"
echo "Staging retained: $work"
