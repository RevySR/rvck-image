# SPDX-License-Identifier: GPL-2.0
label=openEuler
releasever=24.03
hostname=rvck
package_list=euler.list
kernel_excludes="kernel kernel-core kernel-modules kernel-modules-extra"
bootstrap=(filesystem bash coreutils glibc shadow dnf rpm ca-certificates)
weak_deps=False
gpgcheck=True
repo_key=RPM-GPG-KEY-openEuler
configure_rootfs() {
    if [[ -n $password_hash ]]; then
        printf 'root:%s\n' "$(cat "$password_hash")" \
            | chroot "$root" chpasswd -e
    else
        printf '%s\n' 'root:openEuler12#$' | chroot "$root" chpasswd
    fi
    if [[ -n $ssh_key ]]; then
        install -d -m 700 "$root/root/.ssh"
        install -m 600 "$ssh_key" "$root/root/.ssh/authorized_keys"
    fi
    mkdir -p "$root/etc/ssh/sshd_config.d"
    printf 'PermitRootLogin prohibit-password\n' \
        > "$root/etc/ssh/sshd_config.d/10-rvck.conf"
}
