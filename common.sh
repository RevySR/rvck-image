#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:$PATH
REPO_DEFAULT=https://dl-cdn.openeuler.openatom.cn/openEuler-24.03-LTS-SP3/OS/riscv64/rva20/riscv64
die() { echo "error: $*" >&2; exit 1; }
need() { local cmd; for cmd in "$@"; do command -v "$cmd" >/dev/null || die "missing command: $cmd"; done; }
value() { [[ $# -ge 2 && -n $2 ]] || die "missing value for $1"; }
fresh_output() {
    [[ ! -e $1 && ! -L $1 ]] || die "output already exists: $1";
    [[ -d $(dirname "$1") ]] || die "output parent directory does not exist";
}
private_mounts() {
    [[ $EUID == 0 ]] || die "run with sudo/root";
    if [[ ${RVCK_PRIVATE_MOUNTS:-0} != 1 ]]; then
        exec unshare --mount --propagation private env RVCK_PRIVATE_MOUNTS=1 bash "$0" "$@"
    fi
}
check_arch() {
    [[ $(uname -m) == riscv64 ]] && return 0
    local entry
    for entry in /proc/sys/fs/binfmt_misc/*riscv64*; do
        [[ -f $entry ]] || continue
        if grep -q '^enabled' "$entry" && grep -q '^flags:.*F' "$entry"; then return 0; fi
    done
    die "cross build needs enabled qemu-riscv64 binfmt_misc with F flag (qemu-user-static + binfmt-support); otherwise use a riscv64 host"
}
mounts=()
loop=
cleanup() {
    local rc=$? i
    trap - EXIT
    for ((i=${#mounts[@]}-1; i>=0; i--)); do
        umount "${mounts[i]}" || { echo "cannot unmount ${mounts[i]}" >&2; rc=1; }
    done
    if [[ -n $loop ]]; then losetup -d "$loop" || rc=1; fi
    [[ $rc == 0 ]] || echo "Failed; staging files retained at ${work:-unknown}." >&2
    exit "$rc"
}
mount_guest() {
    local root=$1
    mkdir -p "$root"/{dev,proc,sys,run}
    mount --bind /dev "$root/dev"; mounts+=("$root/dev")
    mount -t proc proc "$root/proc"; mounts+=("$root/proc")
    mount -t sysfs -o ro sysfs "$root/sys"; mounts+=("$root/sys")
    mount -t tmpfs tmpfs "$root/run"; mounts+=("$root/run")
}
unmount_guest() {
    local i n=${#mounts[@]}
    for ((i=n-1; i>=n-4; i--)); do umount "${mounts[i]}"; unset 'mounts[i]'; done
}
