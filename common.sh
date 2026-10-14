#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:$PATH
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
EULER_REPO=https://dl-cdn.openeuler.openatom.cn
EULER_REPO+=/openEuler-24.03-LTS-SP3/OS/riscv64/rva20/riscv64
GRUB_URL=$EULER_REPO/EFI/BOOT/grubriscv64.EFI
GRUB_SHA=bf252892f801347e8ac001613b547d18af4618ddad79909cb133d8f70758fbc5
ROOT_TYPE=72ec70a6-cf74-40e6-bd49-4bda08e8f224
die() { echo "error: $*" >&2; exit 1; }
need() {
    local cmd missing=()
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null || missing+=("$cmd")
    done
    ((${#missing[@]} == 0)) || die "install required tools: ${missing[*]}"
}
value() { [[ $# -ge 2 && -n $2 ]] || die "missing value for $1"; }
fresh_output() {
    [[ ! -e $1 && ! -L $1 ]] || die "output already exists: $1"
    [[ -d $(dirname "$1") ]] || die "output parent does not exist"
}
load_profile() {
    case $1 in
        ruyi|euler) source "$SCRIPT_DIR/profiles/$1.sh";;
        *) die "distro must be euler or ruyi";;
    esac
    case $2 in rva20|rva23) ;; *) die "ISA must be rva20 or rva23";; esac
    if [[ $1 == ruyi ]]; then
        default_repo=https://boat.openruyi.cn/stable/$2
    elif [[ $2 == rva23 ]]; then
        default_repo=https://dl-cdn.openeuler.openatom.cn
        default_repo+=/openEuler-24.03-LTS-SP4/OS/riscv64/rva23/riscv64
    else
        default_repo=$EULER_REPO
    fi
}
private_mounts() {
    [[ $EUID == 0 ]] || die "run with sudo/root"
    if [[ ${RVCK_PRIVATE_MOUNTS:-0} != 1 ]]; then
        exec unshare --mount --pid --fork --propagation private \
            env RVCK_PRIVATE_MOUNTS=1 bash "$0" "$@"
    fi
    export SYSTEMD_OFFLINE=1
    if [[ $(uname -m) != riscv64 ]]; then
        export QEMU_CPU=${QEMU_CPU:-max}
    fi
}
mounts=()
cleanup() {
    local rc=$? i
    trap - EXIT
    for ((i=${#mounts[@]}-1; i>=0; i--)); do
        umount -l "${mounts[i]}" || rc=1
    done
    [[ $rc == 0 ]] || echo "Failed; staging retained: ${work:-unknown}" >&2
    exit "$rc"
}
mount_guest() {
    local root=$1 name major minor
    mkdir -p "$root"/{dev,proc,sys,run}
    # Only pseudo devices are needed; never expose host block devices.
    while read -r name major minor; do
        rm -f "$root/dev/$name"
        mknod -m 666 "$root/dev/$name" c "$major" "$minor"
    done <<EOF
null 1 3
zero 1 5
random 1 8
urandom 1 9
tty 5 0
EOF
    ln -snf /proc/self/fd "$root/dev/fd"
    ln -snf /proc/self/fd/0 "$root/dev/stdin"
    ln -snf /proc/self/fd/1 "$root/dev/stdout"
    ln -snf /proc/self/fd/2 "$root/dev/stderr"
    # Bash process substitution in dracut needs /dev/fd -> /proc/self/fd.
    mount -t proc -o nosuid,nodev,noexec proc "$root/proc"
    mounts+=("$root/proc")
}
unmount_guest() {
    local i
    for ((i=${#mounts[@]}-1; i>=0; i--)); do
        umount "${mounts[i]}"
        unset 'mounts[i]'
    done
}
check_arch() {
    [[ $(uname -m) == riscv64 ]] && return 0
    # Probe an existing F-flag handler without changing host registration.
    local probe=$work/arch-probe
    mkdir -p "$probe"
    python3 - "$probe/probe" <<'PY'
import os, struct, sys
code = struct.pack('<III', 0x00000513, 0x05d00893, 0x00000073)
base, offset = 0x10000, 0x100
header = struct.pack('<16sHHIQQQIHHHHHH',
    b'\x7fELF\x02\x01\x01' + bytes(9), 2, 243, 1,
    base + offset, 64, 0, 0, 64, 56, 1, 0, 0, 0)
program = struct.pack('<IIQQQQQQ', 1, 5, 0, base, base,
                      offset + len(code), offset + len(code), 4096)
with open(sys.argv[1], 'wb') as f:
    f.write((header + program).ljust(offset, b'\0') + code)
os.chmod(sys.argv[1], 0o755)
PY
    chroot "$probe" /probe || die \
        "enable qemu-riscv64 binfmt with the F flag, or build natively"
}
